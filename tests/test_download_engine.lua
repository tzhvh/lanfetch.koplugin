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

-- Format neutrality: the sanitizer never rewrites a non-PDF name to PDF
assert_eq(DownloadEngine.sanitizeFilename("book.epub"), "book.epub", "EPUB extension kept (no .pdf forcing)")
assert_eq(DownloadEngine.sanitizeFilename("notes.md"), "notes.md", "Markdown extension kept")
assert_eq(DownloadEngine.sanitizeFilename("photo?1"), "photo_1", "extensionless name stays bare without a content type")
assert_eq(DownloadEngine.sanitizeFilename(nil), "download", "bare fallback name has no forced extension")

-- Content-Type → extension completion (extensionless names only)
assert_eq(DownloadEngine.extensionForContentType("application/pdf"), ".pdf", "pdf mime maps")
assert_eq(DownloadEngine.extensionForContentType("APPLICATION/EPUB+ZIP"), ".epub", "mime lookup case-insensitive")
assert_eq(DownloadEngine.extensionForContentType("text/html; charset=utf-8"), ".html", "content-type parameters stripped")
assert_eq(DownloadEngine.extensionForContentType("application/x-unknown"), nil, "unknown mime → nil")
assert_eq(DownloadEngine.sanitizeFilename("book", nil, "application/pdf"), "book.pdf", "pdf content type completes name")
assert_eq(DownloadEngine.sanitizeFilename("book", nil, "application/epub+zip"), "book.epub", "epub content type completes name")
assert_eq(DownloadEngine.sanitizeFilename("book", nil, "text/markdown; charset=utf-8"), "book.md", "markdown content type completes name")
assert_eq(DownloadEngine.sanitizeFilename("book", nil, "application/x-unknown"), "book", "unmapped content type leaves name bare")
assert_eq(DownloadEngine.sanitizeFilename("book.epub", nil, "application/pdf"), "book.epub",
    "the name's own extension wins over the content type")

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

-- ═══ Interleaved mock-server tests ═══
-- The yieldable transport lets one thread drive both sides: the engine runs in a
-- coroutine and yields during connect/reads, and the harness pumps the mock
-- server between engine yields.

local function run_interleaved(client_fn, serve_fn)
    local co = coroutine.create(client_fn)
    while true do
        local ok, result = coroutine.resume(co)
        if not ok then
            error("client coroutine errored: " .. tostring(result))
        end
        if coroutine.status(co) == "dead" then
            return result
        end
        serve_fn()
    end
end

-- Mock server: accepts one connection per pump, reads the request, serves the
-- next scripted response, closes.
local function scripted_server(responses)
    local server = socket.bind("127.0.0.1", 0)
    local _, port = server:getsockname()
    server:settimeout(0.01)
    local next_response = 1
    local serve = function()
        local client = server:accept()
        if not client then return end
        client:settimeout(0.05)
        local line = client:receive("*l")
        while line and line ~= "" do
            line = client:receive("*l")
        end
        if next_response <= #responses then
            client:send(responses[next_response])
            next_response = next_response + 1
        end
        client:close()
    end
    return serve, port
end

print("== Yieldable transport: interleaved streaming download ==")
do
    local payload = string.rep("AB", 8192) -- 16 KB
    local response = string.format(
        "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: %d\r\nContent-Disposition: attachment; filename=\"streamed.pdf\"\r\n\r\n%s",
        #payload, payload)
    local serve, port = scripted_server({ response })
    local sandbox2 = tmp_dir .. "/lanfetch_stream_" .. tostring(os.time())
    os.execute("mkdir -p " .. sandbox2)

    local progress_calls = 0
    local last_bytes = 0
    local outcome = run_interleaved(
        function()
            return DownloadEngine.download(
                string.format("http://127.0.0.1:%d/document.pdf", port),
                sandbox2, {}, 
                function(rec)
                    progress_calls = progress_calls + 1
                    assert_eq(rec >= last_bytes, true, "progress bytes monotonic")
                    last_bytes = rec
                    return true
                end,
                nil,
                function() coroutine.yield() end)
        end,
        serve)

    assert_eq(outcome.kind, KIND.COMPLETED, "streaming download completes")
    assert_outcome_uniform(outcome, "streaming download")
    assert_eq(outcome.meta.filename, "streamed.pdf", "filename from Content-Disposition")
    assert_eq(outcome.meta.size, #payload, "meta.size matches payload")
    assert_eq(last_bytes, #payload, "progress reached full payload")
    assert_eq(progress_calls > 0, true, "progress callback fired")
    local fh = assert(io.open(outcome.path, "rb"))
    local saved = fh:read("*a")
    fh:close()
    assert_eq(#saved, #payload, "saved file size matches payload")
    assert_eq(saved == payload, true, "saved file content byte-identical")
    os.execute("rm -rf " .. sandbox2)
end

print("== Yieldable transport: non-PDF downloads keep their format ==")
do
    -- An EPUB whose Content-Disposition name carries no extension: the
    -- response Content-Type must complete it (previously became ".epub.pdf").
    local payload = string.rep("EPUB", 128)
    local response = string.format(
        "HTTP/1.1 200 OK\r\nContent-Type: application/epub+zip\r\nContent-Length: %d\r\nContent-Disposition: attachment; filename=\"mybook\"\r\n\r\n%s",
        #payload, payload)
    local serve, port = scripted_server({ response })
    local sandbox3 = tmp_dir .. "/lanfetch_epub_" .. tostring(os.time())
    os.execute("mkdir -p " .. sandbox3)

    local outcome = run_interleaved(
        function()
            return DownloadEngine.download(
                string.format("http://127.0.0.1:%d/get", port), sandbox3, {},
                nil, nil, function() coroutine.yield() end)
        end,
        serve)

    assert_eq(outcome.kind, KIND.COMPLETED, "epub download completes")
    assert_eq(outcome.meta.filename, "mybook.epub", "content-type completes extensionless name")
    assert_eq(outcome.meta.content_type, "application/epub+zip", "content type recorded in meta")

    -- An extensionless URL served as a zip: filename derives from URL + type
    local zip_magic = string.char(0x50, 0x4B) .. string.rep("z", 64)
    local response2 = string.format(
        "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: %d\r\n\r\n%s",
        #zip_magic, zip_magic)
    local serve2, port2 = scripted_server({ response2 })
    local outcome2 = run_interleaved(
        function()
            return DownloadEngine.download(
                string.format("http://127.0.0.1:%d/docs/handbook", port2), sandbox3, {},
                nil, nil, function() coroutine.yield() end)
        end,
        serve2)
    assert_eq(outcome2.kind, KIND.COMPLETED, "zip download completes")
    assert_eq(outcome2.meta.filename, "handbook.zip", "URL stem completed with zip extension")
    os.execute("rm -rf " .. sandbox3)
end

print("== Yieldable transport: CANCEL lands mid-connect ==")
do
    local aborted = false
    local t0 = socket.gettime()
    local outcome = run_interleaved(
        function()
            return DownloadEngine.download("http://10.255.255.1/doc.pdf", tmp_dir, {}, nil,
                function() return aborted end,
                function() coroutine.yield() end)
        end,
        function() aborted = true end) -- first engine yield triggers the cancel

    local elapsed = socket.gettime() - t0
    assert_eq(outcome.kind, KIND.ABORTED, "mid-connect abort returns ABORTED")
    assert_outcome_uniform(outcome, "mid-connect abort")
    assert_eq(elapsed < 3, true, string.format("abort landed fast (%.2fs), not after 10s cap", elapsed))
end

print("== Yieldable transport: probe is cancellable and redirect-aware ==")
do
    -- Redirect hop then 200 with Content-Disposition
    local redirect = "HTTP/1.1 302 Found\r\nLocation: /final%20report.pdf\r\nContent-Length: 0\r\n\r\n"
    local final = 'HTTP/1.1 200 OK\r\nContent-Length: 1234\r\nContent-Disposition: attachment; filename="probed.pdf"\r\n\r\n'
    local serve, port = scripted_server({ redirect, final })

    local name, final_url, size = nil, nil, nil
    run_interleaved(
        function()
            name, final_url, size = DownloadEngine.probeRemoteMetadata(
                string.format("http://127.0.0.1:%d/", port), 4,
                nil, function() coroutine.yield() end)
            coroutine.yield() -- let harness observe completion cleanly
        end,
        serve)

    assert_eq(name, "probed.pdf", "probe follows redirect and reads Content-Disposition")
    assert_eq(size, 1234, "probe reports Content-Length")
    assert_eq(final_url:find("final%%20report%.pdf") ~= nil, true, "probe reports redirect-resolved URL")

    -- Cancellable: unroutable target, abort on first yield
    local aborted = false
    local t0 = socket.gettime()
    run_interleaved(
        function()
            DownloadEngine.probeRemoteMetadata("http://10.255.255.1/", 4,
                function() return aborted end,
                function() coroutine.yield() end)
        end,
        function() aborted = true end)
    assert_eq(socket.gettime() - t0 < 3, true, "probe abort lands within one poll interval, not 4s")
end

print("== Yieldable transport: TLS handshake failure is a fast FAILED ==")
do
    local response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi" -- plaintext
    local serve, port = scripted_server({ response })
    local outcome = run_interleaved(
        function()
            return DownloadEngine.download(string.format("https://127.0.0.1:%d/doc.pdf", port), tmp_dir, {},
                nil, nil, function() coroutine.yield() end)
        end,
        serve)
    assert_eq(outcome.kind, KIND.FAILED, "TLS to plaintext server fails")
    assert_eq(outcome.error and outcome.error:find("SSL handshake") ~= nil, true,
        "TLS failure names the handshake")
end

if failures > 0 then
    print(string.format("%d test(s) FAILED", failures))
    os.exit(1)
end
print("All DownloadEngine terminal funnel and metadata tests passed.")
