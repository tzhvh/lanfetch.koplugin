-- tests/smoke_archive_extractor_koreader.lua
-- Real-libarchive round trip: builds actual .zip files on disk, then extracts
-- them through ArchiveExtractor using KOReader's real ffi/archiver module and
-- libarchive — the same code path the device will run. Not part of the plain
-- `lua` suite; run it under KOReader's luajit with the install tree available:
--
--   cd <repo>
--   KR=/path/to/koreader-install-dir
--   LD_LIBRARY_PATH="$KR/libs" "$KR/luajit" tests/smoke_archive_extractor_koreader.lua "$KR"

local kr_dir = arg and arg[1]
assert(kr_dir and kr_dir ~= "", "pass the KOReader install directory as the first argument")
package.path = kr_dir .. "/?.lua;" .. kr_dir .. "/frontend/?.lua;lanfetch.koplugin/?.lua;" .. package.path
package.cpath = kr_dir .. "/?.so;" .. package.cpath

-- reader.lua loads ffi/loadlib via setupkoenv before any plugin code runs;
-- it installs ffi.loadlib, which ffi/archiver needs to find versioned libs
-- (libarchive.so.13) in the KOReader libs directory.
require("ffi/loadlib")

local ArchiveExtractor = require("archive_extractor")
local lfs = require("libs/libkoreader-lfs")

local failures = 0
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end
local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end

local work = (os.getenv("TMPDIR") or "/tmp") .. "/lanfetch_smoke_" .. tostring(os.time())
os.execute("rm -rf " .. work)
os.execute("mkdir -p " .. work .. "/src/nested")
local fh = assert(io.open(work .. "/src/alpha.txt", "wb")); fh:write("alpha payload"); fh:close()
local fh = assert(io.open(work .. "/src/nested/beta.md", "wb")); fh:write("# beta"); fh:close()
os.execute(string.format("printf 'unicode content' > '%s/src/h%c%cllo.pdf'", work, 0xC3, 0xA9))
os.execute("cd " .. work .. "/src && zip -qr ../bundle.zip .")

print("== smoke: real zip round trip through ffi/archiver ==")
do
    assert_eq(lfs.attributes(work .. "/bundle.zip", "mode"), "file", "fixture zip created")
    local res = ArchiveExtractor.extract(work .. "/bundle.zip", work .. "/out/bundle", {})
    assert_eq(res.ok, true, "real extraction succeeds: " .. tostring(res.error))
    assert_eq(res.files, 3, "three files extracted")
    assert_eq(read_file(work .. "/out/bundle/alpha.txt"), "alpha payload", "file content byte-identical")
    assert_eq(read_file(work .. "/out/bundle/nested/beta.md"), "# beta", "nested file content byte-identical")
    assert_eq(read_file(work .. "/out/bundle/héllo.pdf"), "unicode content", "unicode filename survived")
    -- second extraction into a fresh dest overwrites cleanly
    local res2 = ArchiveExtractor.extract(work .. "/bundle.zip", work .. "/out/bundle2", {})
    assert_eq(res2.ok, true, "re-extraction into a new dest succeeds")
end

print("== smoke: corrupt archive fails cleanly ==")
do
    local bad = work .. "/corrupt.zip"
    local fh = assert(io.open(bad, "wb")); fh:write("PK\x03\x04 not really a zip"); fh:close()
    local res = ArchiveExtractor.extract(bad, work .. "/out/corrupt", {})
    assert_eq(res.ok, false, "corrupt archive rejected")
    assert_eq(lfs.attributes(work .. "/out/corrupt"), nil, "no dest left behind")
end

print("== smoke: zip-slip archive rejected by the Lua guard ==")
do
    -- `zip` sanitizes paths, so craft the malicious archive with python zipfile
    local slip = work .. "/slip.zip"
    os.execute(string.format(
        [[python3 -c "import zipfile; z=zipfile.ZipFile('%s','w'); z.writestr('../escaped.txt','x'); z.writestr('ok.txt','y'); z.close()"]],
        slip))
    assert_eq(lfs.attributes(slip, "mode"), "file", "slip fixture created")
    local res = ArchiveExtractor.extract(slip, work .. "/out/slip", {})
    assert_eq(res.ok, false, "zip-slip rejected")
    assert_eq(res.error and res.error:find("unsafe", 1, true) ~= nil, true, "error names the unsafe path")
    assert_eq(lfs.attributes(work .. "/out/slip"), nil, "partial dest purged")
    assert_eq(lfs.attributes(work .. "/escaped.txt"), nil, "nothing escaped the dest")
    assert_eq(lfs.attributes(work .. "/out/bundle/alpha.txt") ~= nil, true,
        "earlier successful extraction untouched by the purge")
end

os.execute("rm -rf " .. work)

if failures > 0 then
    print(string.format("%d smoke test(s) FAILED", failures))
    os.exit(1)
end
print("All ArchiveExtractor libarchive smoke tests passed.")
