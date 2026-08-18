-- tests/test_http_hop.lua
-- Exercises http_hop.performGet directly against an interleaved mock server.
--   lua tests/test_http_hop.lua
package.path = "lanfetch.koplugin/?.lua;" .. package.path
local socket = require("socket")
local http_hop = require("http_hop")

local failures = 0
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

local function run_interleaved(client_fn, serve_fn)
    local co = coroutine.create(client_fn)
    while true do
        local ok, r1, r2 = coroutine.resume(co)
        if not ok then error("client coroutine errored: " .. tostring(r1)) end
        if coroutine.status(co) == "dead" then return r1, r2 end
        serve_fn()
    end
end

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

print("== http_hop: 200 hop returns parsed headers and body-positioned client ==")
do
    local serve, port = scripted_server({
        "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: 5\r\nX-Custom: v \r\n\r\nhello",
    })
    local result
    run_interleaved(
        function()
            local ok, res = http_hop.performGet(
                string.format("http://127.0.0.1:%d/doc.pdf", port),
                { yield_callback = function() coroutine.yield() end })
            result = res
            coroutine.yield(0) -- placeholder to satisfy harness shape
        end,
        serve)
    local ok, res = true, result
    assert_eq(res.code, 200, "status code parsed")
    assert_eq(res.headers["content-type"], "application/pdf", "headers lowercased")
    assert_eq(res.headers["x-custom"], "v", "header trailing whitespace trimmed")
    assert_eq(res.headers["content-length"], "5", "content-length surfaced")
    -- client positioned at body: first chunk read returns the payload
    local body = res.client:receive("*a")
    res.client:close()
    assert_eq(body, "hello", "client positioned at body start")
end

print("== http_hop: non-default port lands in Host header ==")
do
    local full_request
    local server = socket.bind("127.0.0.1", 0)
    local _, port = server:getsockname()
    server:settimeout(0.05)
    run_interleaved(
        function()
            http_hop.performGet(string.format("http://127.0.0.1:%d/x", port),
                { yield_callback = function() coroutine.yield() end })
        end,
        function()
            local c = server:accept()
            if c then
                full_request = ""
                c:settimeout(0.05)
                local line = c:receive("*l")
                while line and line ~= "" do
                    full_request = full_request .. line .. "\n"
                    line = c:receive("*l")
                end
                c:send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                c:close()
            end
        end)
    assert_eq(full_request ~= nil, true, "request reached server")
    assert_eq(full_request:find(string.format("Host: 127.0.0.1:%d", port), 1, true) ~= nil, true,
        "non-default port appears in Host header")
    assert_eq(full_request:find("GET /x HTTP/1.1", 1, true) ~= nil, true,
        "request line carries path")
end

print("== http_hop: abort mid-connect returns the aborted sentinel ==")
do
    local aborted = false
    local ok, res = run_interleaved(
        function()
            return http_hop.performGet("http://10.255.255.1/x",
                { abort_checker = function() return aborted end,
                  yield_callback = function() coroutine.yield() end })
        end,
        function() aborted = true end)
    assert_eq(ok, false, "hop reports failure")
    assert_eq(res, "aborted", "aborted sentinel, not an error table")
end

print("== http_hop: malformed status line reports its stage ==")
do
    local serve, port = scripted_server({ "GARBAGE\r\n\r\n" })
    local ok, res = run_interleaved(
        function()
            return http_hop.performGet(string.format("http://127.0.0.1:%d/x", port),
                { yield_callback = function() coroutine.yield() end })
        end,
        serve)
    assert_eq(ok, false, "garbage status fails")
    assert_eq(res.stage, "malformed_status", "stage identifies malformed status line")
    assert_eq(res.detail, "GARBAGE", "detail carries the raw line")
end

if failures > 0 then
    print(string.format("%d test(s) FAILED", failures))
    os.exit(1)
end
print("All http_hop tests passed.")
