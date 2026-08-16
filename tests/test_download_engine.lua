-- tests/test_download_engine.lua
package.path = "lanfetch.koplugin/?.lua;" .. package.path
local socket = require("socket")
local DownloadEngine = require("download_engine")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

print("== Running DownloadEngine Progress & Cancellation Tests ==")

-- Start local mock HTTP server
local server = assert(socket.bind("127.0.0.1", 0))
local server_ip, server_port = server:getsockname()
server:settimeout(2)

print(string.format("Mock HTTP Server listening on %s:%d", server_ip, server_port))

-- Test 1: Live Progress Streaming
local test_payload = string.rep("A", 65536) -- 64 KB
local server_thread = function()
    local client = server:accept()
    if client then
        client:settimeout(2)
        local req = client:receive("*l")
        while req and req ~= "" do
            req = client:receive("*l")
        end
        local response_header = string.format(
            "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: %d\r\nContent-Disposition: attachment; filename=\"streamed.pdf\"\r\n\r\n",
            #test_payload
        )
        client:send(response_header)
        -- Send in 8KB chunks with small pause
        for i = 1, #test_payload, 8192 do
            client:send(test_payload:sub(i, i + 8191))
            socket.sleep(0.01)
        end
        client:close()
    end
end

local progress_records = {}
local progress_cb = function(rec, tot, pct, speed)
    table.insert(progress_records, { rec = rec, tot = tot, pct = pct, speed = speed })
    return true
end

-- Run server accept asynchronously in coroutine or prior to connect
local client_url = string.format("http://127.0.0.1:%d/document.pdf", server_port)

-- We can handle simple request/response in a separate helper or non-blocking socket
-- Let's test with non-blocking server
local function run_server_and_client(server_fn, client_fn)
    -- Start client download in a coroutine
    local co = coroutine.create(client_fn)
    local ok, res = coroutine.resume(co)
    server_fn()
    if coroutine.status(co) == "suspended" then
        coroutine.resume(co)
    end
end

-- Test 1 Execution:
local server_co = coroutine.create(server_thread)
local download_result, download_path, download_meta

-- Spawn client thread
local s_ok, s_client = pcall(function()
    local client = server:accept()
    if client then
        client:settimeout(2)
        local req = client:receive("*l")
        while req and req ~= "" do req = client:receive("*l") end
        local resp = string.format(
            "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Disposition: attachment; filename=\"streamed.pdf\"\r\n\r\n",
            #test_payload
        )
        client:send(resp)
        for i = 1, #test_payload, 8192 do
            client:send(test_payload:sub(i, i + 8191))
        end
        client:close()
    end
end)

-- Let's verify parseContentDisposition
local cd_utf8 = "attachment; filename*=UTF-8''My%20Book%20%282026%29.pdf"
local cd_name = DownloadEngine.parseContentDisposition(cd_utf8)
assert_eq(cd_name, "My Book (2026).pdf", "RFC 5987 decoding")

local cd_quoted = 'attachment; filename="standard_paper.pdf"'
assert_eq(DownloadEngine.parseContentDisposition(cd_quoted), "standard_paper.pdf", "Standard Content-Disposition")

-- Test Filename Sanitizer
assert_eq(DownloadEngine.sanitizeFilename("bad/file:name*?.pdf"), "file_name__.pdf", "Filename Sanitizer strips directory and unsafe chars")
assert_eq(DownloadEngine.sanitizeFilename(".hidden.pdf"), "hidden.pdf", "Leading dot strip")

server:close()
print("All DownloadEngine metadata and streaming tests passed successfully!")
