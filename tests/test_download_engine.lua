-- tests/test_download_engine.lua
-- Terminal funnel contract + filename metadata tests. Runs headless with plain lua:
--   lua tests/test_download_engine.lua
package.path = "lanfetch.koplugin/?.lua;" .. package.path
local socket = require("socket")
local DownloadEngine = require("download_engine")
local KIND = DownloadEngine.KIND

local failures = 0
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

-- The uniform-outcome contract: meta is always a table, path/error are nil or
-- strings, and error is nil exactly when kind ~= FAILED.
local function assert_outcome_uniform(out, label)
    assert_eq(type(out), "table", label .. ": outcome is a table")
    assert_eq(type(out.meta), "table", label .. ": meta is always a table")
    assert_eq(out.path == nil or type(out.path) == "string", true, label .. ": path nil-or-string")
    assert_eq(out.error == nil or type(out.error) == "string", true, label .. ": error nil-or-string")
    if out.kind == KIND.FAILED then
        assert_eq(type(out.error), "string", label .. ": FAILED carries an error message")
        assert_eq(out.path, nil, label .. ": FAILED has no path")
    else
        assert_eq(out.error, nil, label .. ": non-FAILED has no error")
    end
    if out.kind == KIND.COMPLETED then
        assert_eq(type(out.path), "string", label .. ": COMPLETED carries a path")
    else
        assert_eq(out.path, nil, label .. ": non-COMPLETED has no path")
    end
end

print("== DownloadEngine terminal funnel & metadata tests ==")

-- KIND constants
assert_eq(KIND.COMPLETED, "completed", "KIND.COMPLETED")
assert_eq(KIND.ABORTED, "aborted", "KIND.ABORTED")
assert_eq(KIND.FAILED, "failed", "KIND.FAILED")

-- Content-Disposition parsing
assert_eq(DownloadEngine.parseContentDisposition("attachment; filename*=UTF-8''My%20Book%20%282026%29.pdf"),
    "My Book (2026).pdf", "RFC 5987 decoding")
assert_eq(DownloadEngine.parseContentDisposition('attachment; filename="standard_paper.pdf"'),
    "standard_paper.pdf", "Standard Content-Disposition")

-- Filename sanitizer
assert_eq(DownloadEngine.sanitizeFilename("bad/file:name*?.pdf"), "file_name__.pdf",
    "Sanitizer strips directory and unsafe chars")
assert_eq(DownloadEngine.sanitizeFilename(".hidden.pdf"), "hidden.pdf", "Leading dot strip")

local tmp_dir = os.getenv("TMPDIR") or "/tmp"
local sandbox = tmp_dir .. "/lanfetch_test_" .. tostring(os.time())
os.execute("mkdir -p " .. sandbox)

-- Funnel contract: immediate abort (no network touched — abort is checked first)
local out = DownloadEngine.download("http://192.0.2.1/doc.pdf", sandbox, {}, nil, function() return true end)
assert_eq(out.kind, KIND.ABORTED, "pre-abort returns ABORTED")
assert_outcome_uniform(out, "pre-abort")

-- Funnel contract: invalid URL → FAILED
out = DownloadEngine.download("not a url", sandbox)
assert_eq(out.kind, KIND.FAILED, "invalid URL returns FAILED")
assert_outcome_uniform(out, "invalid URL")

-- Funnel contract: connection refused → FAILED with real error (localhost closed port)
local closer = socket.bind("127.0.0.1", 0)
local _, closed_port = closer:getsockname()
closer:close()
out = DownloadEngine.download(string.format("http://127.0.0.1:%d/doc.pdf", closed_port), sandbox)
assert_eq(out.kind, KIND.FAILED, "refused connection returns FAILED")
assert_eq(out.error and out.error:find("refused") ~= nil, true, "refused connection names the cause")
assert_outcome_uniform(out, "refused connection")
-- Failure must not leave temp files behind
local leftover = io.popen("ls -a " .. sandbox .. " 2>/dev/null | grep -c lanfetch_ || true")
assert_eq(tonumber(leftover:read("*l") or "0"), 0, "no .lanfetch tmp left after failure")
leftover:close()

os.execute("rm -rf " .. sandbox)

if failures > 0 then
    print(string.format("%d test(s) FAILED", failures))
    os.exit(1)
end
print("All DownloadEngine terminal funnel and metadata tests passed.")
