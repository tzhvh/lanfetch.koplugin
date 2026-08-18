-- tests/test_archive_extractor.lua
-- ArchiveExtractor contract tests with a fake ffi/archiver (real filesystem
-- via lfs). Runs headless with plain lua:
--   lua tests/test_archive_extractor.lua
package.path = "lanfetch.koplugin/?.lua;" .. package.path
local ArchiveExtractor = require("archive_extractor")

local lfs = require("lfs")

local failures = 0
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local tmp_dir = os.getenv("TMPDIR") or "/tmp"
local sandbox_root = tmp_dir .. "/lanfetch_extract_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local function fresh_dest(name)
    local dir = sandbox_root .. "/" .. name
    lfs.mkdir(sandbox_root)
    return dir
end

-- Fake archiver mimicking the real Reader surface the extractor uses:
-- open(path), iterate() over scripted entries, extractToPath(key, dest), close().
local function make_fake_archiver(entries, script)
    script = script or {}
    local record = { opened = nil, closes = 0, extracted = {} }
    local Reader = {}
    function Reader:new()
        local arc = { err = nil }
        function arc:open(path)
            if script.open_fail then
                self.err = "cannot read archive"
                return nil
            end
            record.opened = path
            return true
        end
        function arc:iterate()
            local i = 0
            return function()
                i = i + 1
                local e = entries[i]
                if type(e) == "function" then e = e(i) end -- dynamic per-entry hook
                if e then return e end
                return nil
            end, self
        end
        function arc:extractToPath(key, dest)
            if script.fail_on == key then
                self.err = "disk error"
                return false
            end
            record.extracted[#record.extracted + 1] = { key = key, dest = dest }
            -- Materialize like libarchive would, so purge paths have content
            local fh = io.open(dest, "wb")
            if fh then fh:write("data"); fh:close() end
            return true
        end
        function arc:close()
            record.closes = record.closes + 1
        end
        return arc
    end
    return { Reader = Reader }, record
end

local FILE = function(path, size) return { path = path, mode = "file", size = size or 10 } end
local DIR = function(path) return { path = path, mode = "directory", size = 0 } end

print("== ArchiveExtractor: entry path safety ==")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("../evil.txt"), true, "dot-dot parent escape")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("good/../../evil"), true, "nested dot-dot escape")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("/etc/passwd"), true, "absolute path")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("..\\evil.txt"), true, "backslash separator")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("C:\\evil"), true, "drive letter")
assert_eq(ArchiveExtractor.isUnsafeEntryPath(""), true, "empty path")
assert_eq(ArchiveExtractor.isUnsafeEntryPath(nil), true, "nil path")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("a/b/c.txt"), false, "normal relative path is safe")
assert_eq(ArchiveExtractor.isUnsafeEntryPath("..dots/in-name.pdf"), false, "literal dots inside a segment are fine")

print("== ArchiveExtractor: happy path extracts under dest, dir entries created ==")
do
    local dest = fresh_dest("happy")
    local archiver, record = make_fake_archiver{
        DIR("sub"), FILE("a.txt", 5), FILE("sub/b.md", 7),
    }
    local yields = 0
    local res = ArchiveExtractor.extract("/fake/bundle.zip", dest, {
        archiver = archiver,
        yield_fn = function() yields = yields + 1 end,
    })
    assert_eq(res.ok, true, "clean extraction succeeds")
    assert_eq(res.files, 2, "file count excludes directory entries")
    assert_eq(res.error, nil, "no error on success")
    assert_eq(yields, 3, "yield pumped once per entry")
    assert_eq(record.extracted[1].dest, dest .. "/a.txt", "entry extracted under dest dir")
    assert_eq(record.extracted[2].dest, dest .. "/sub/b.md", "nested entry keeps its subpath")
    assert_eq(exists(dest .. "/a.txt"), true, "fake materialized file present")
    assert_eq(exists(dest .. "/sub"), true, "directory entry created")
    assert_eq(record.closes, 1, "archive closed once")
end

print("== ArchiveExtractor: any failure purges the partial destination ==")
do
    -- Unsafe entry path (zip-slip): refuse and leave nothing behind
    local dest = fresh_dest("slip")
    local archiver = make_fake_archiver{ FILE("good.txt"), FILE("../evil.txt") }
    local res = ArchiveExtractor.extract("/fake/x.zip", dest, { archiver = archiver })
    assert_eq(res.ok, false, "zip-slip rejected")
    assert_eq(res.error:find("unsafe", 1, true) ~= nil, true, "error names the unsafe path")
    assert_eq(exists(dest), false, "partial dest removed after unsafe entry")

    -- libarchive extraction failure mid-archive
    local dest2 = fresh_dest("midfail")
    local archiver2 = make_fake_archiver({ FILE("one.txt"), FILE("two.txt") }, { fail_on = "two.txt" })
    local res2 = ArchiveExtractor.extract("/fake/x.zip", dest2, { archiver = archiver2 })
    assert_eq(res2.ok, false, "mid-archive failure fails extraction")
    assert_eq(res2.error:find("two.txt", 1, true) ~= nil, true, "error names the failing entry")
    assert_eq(exists(dest2), false, "partial dest removed after extraction failure")

    -- Duplicate entry paths would confuse the archiver's path-keyed seeking
    local dest3 = fresh_dest("dup")
    local archiver3 = make_fake_archiver{ FILE("same.txt"), FILE("same.txt") }
    local res3 = ArchiveExtractor.extract("/fake/x.zip", dest3, { archiver = archiver3 })
    assert_eq(res3.ok, false, "duplicate entry paths rejected")
    assert_eq(exists(dest3), false, "partial dest removed after duplicate")

    -- Unopenable archive
    local dest4 = fresh_dest("badopen")
    local archiver4 = make_fake_archiver({ FILE("a.txt") }, { open_fail = true })
    local res4 = ArchiveExtractor.extract("/fake/x.zip", dest4, { archiver = archiver4 })
    assert_eq(res4.ok, false, "open failure fails extraction")
    assert_eq(exists(dest4), false, "no dest left behind on open failure")
end

print("== ArchiveExtractor: abort between entries purges dest ==")
do
    local dest = fresh_dest("abort")
    local aborted = false
    local archiver = make_fake_archiver{
        FILE("one.txt"),
        FILE("two.txt"), -- extracted or not, the next abort check stops here
    }
    local res = ArchiveExtractor.extract("/fake/x.zip", dest, {
        archiver = archiver,
        abort_checker = function() return aborted end,
        -- flip the flag on the first yield, i.e. after the first entry
        yield_fn = function() aborted = true end,
    })
    assert_eq(res.ok, false, "aborted extraction fails")
    assert_eq(res.aborted, true, "aborted flag surfaced")
    assert_eq(exists(dest), false, "partial dest removed after abort")
end

print("== ArchiveExtractor: archive bomb caps ==")
do
    local dest = fresh_dest("bomb_entries")
    local orig_max = ArchiveExtractor.MAX_ENTRIES
    ArchiveExtractor.MAX_ENTRIES = 2
    local archiver = make_fake_archiver{ FILE("1"), FILE("2"), FILE("3") }
    local res = ArchiveExtractor.extract("/fake/x.zip", dest, { archiver = archiver })
    assert_eq(res.ok, false, "entry-count cap enforced")
    assert_eq(res.error:find("too many entries", 1, true) ~= nil, true, "entry cap error message")
    assert_eq(exists(dest), false, "dest purged on entry cap")
    ArchiveExtractor.MAX_ENTRIES = orig_max

    local dest2 = fresh_dest("bomb_bytes")
    local orig_bytes = ArchiveExtractor.MAX_TOTAL_BYTES
    ArchiveExtractor.MAX_TOTAL_BYTES = 100
    local archiver2 = make_fake_archiver{ FILE("a", 60), FILE("b", 60) }
    local res2 = ArchiveExtractor.extract("/fake/x.zip", dest2, { archiver = archiver2 })
    assert_eq(res2.ok, false, "total-size cap enforced")
    assert_eq(exists(dest2), false, "dest purged on size cap")
    ArchiveExtractor.MAX_TOTAL_BYTES = orig_bytes
end

print("== ArchiveExtractor: guard rails ==")
do
    local dest = fresh_dest("empty")
    local archiver = make_fake_archiver{}
    local res = ArchiveExtractor.extract("/fake/x.zip", dest, { archiver = archiver })
    assert_eq(res.ok, false, "empty archive fails")
    assert_eq(res.error:find("empty", 1, true) ~= nil, true, "empty archive error message")

    local res2 = ArchiveExtractor.extract("/fake/missing.zip", fresh_dest("missing"), {})
    assert_eq(res2.ok, false, "missing archive file fails")
    assert_eq(res2.error:find("not found", 1, true) ~= nil, true, "missing archive error message")

    -- No injected archiver and no real ffi/archiver on this headless host:
    -- the archive file itself must exist so the flow reaches archiver lookup
    local dummy = sandbox_root .. "/dummy.zip"
    local fh = io.open(dummy, "wb"); fh:write("PK"); fh:close()
    local res3 = ArchiveExtractor.extract(dummy, fresh_dest("nofake"), {})
    assert_eq(res3.ok, false, "headless without archiver fails cleanly")
    assert_eq(res3.error:find("archiver", 1, true) ~= nil, true, "archiver unavailability named")

    -- Non-file, non-directory entry types are skipped, not materialized
    local dest4 = fresh_dest("weird")
    local archiver4 = make_fake_archiver{
        { path = "link", mode = "link", size = 0 },
        { path = "dev", mode = "char device", size = 0 },
        FILE("real.txt"),
    }
    local res4 = ArchiveExtractor.extract("/fake/x.zip", dest4, { archiver = archiver4 })
    assert_eq(res4.ok, true, "links/devices skipped without failing")
    assert_eq(res4.files, 1, "only the real file counted")
    assert_eq(exists(dest4 .. "/link"), false, "link entry not materialized")
end

os.execute("rm -rf " .. sandbox_root)

if failures > 0 then
    print(string.format("%d test(s) FAILED", failures))
    os.exit(1)
end
print("All ArchiveExtractor contract tests passed.")
