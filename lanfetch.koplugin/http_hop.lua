--[[--
HTTP Hop: one yieldable HTTP GET hop — URL parse, TCP connect, optional TLS,
request send, status line, and response headers. The body (or the redirect
decision) belongs to the caller; the returned client is positioned at the start
of the body.

Every socket operation runs through the yieldable poll transport (short
per-socket timeouts, abort check before each yield), so a hop is cancellable
mid-connect and keeps the host event loop pumping.
--]]--

local socket = require("socket")
local ssl = pcall(require, "ssl") and require("ssl") or nil
local url_util = require("socket.url")

local HTTPHop = {}

--- Poll interval: every blocking socket operation is retried at this
--- granularity; the abort checker runs before each yield, so CANCEL lands
--- within one interval even during connect or TLS handshake.
HTTPHop.POLL_INTERVAL = 0.2

local POLL_INTERVAL = HTTPHop.POLL_INTERVAL

local function poll_aborted(opts)
    return opts.abort_checker and opts.abort_checker()
end

--- Yieldable connect: retries the same socket (verified on Linux/LuaSocket — a
--- timed-out connect leaves the socket reusable) until connected, refused, aborted,
--- or the wall-clock cap expires. Aborts are checked before yielding.
local function poll_connect(sock, host, port, opts)
    local deadline = socket.gettime() + (opts.connect_timeout or 10)
    sock:settimeout(POLL_INTERVAL)
    while true do
        local ok, err = sock:connect(host, port)
        if ok then
            return true
        elseif err == "timeout" then
            if poll_aborted(opts) then return nil, "aborted" end
            if socket.gettime() >= deadline then return nil, "timeout" end
            if opts.yield_callback then opts.yield_callback() end
        else
            return nil, err
        end
    end
end

--- Yieldable TLS handshake: LuaSec surfaces "want read"/"want write" while the
--- handshake is in flight; poll those with abort checks and yields.
local function poll_handshake(sock, opts)
    local deadline = socket.gettime() + (opts.connect_timeout or 10)
    sock:settimeout(POLL_INTERVAL)
    while true do
        local ok, err = sock:dohandshake()
        if ok then
            return true
        elseif err == "want read" or err == "want write" or err == "timeout" then
            if poll_aborted(opts) then return nil, "aborted" end
            if socket.gettime() >= deadline then return nil, "timeout" end
            if opts.yield_callback then opts.yield_callback() end
        else
            return nil, err
        end
    end
end

--- Yieldable send: resumes from the last byte index on partial sends.
local function poll_send(sock, data, opts)
    local deadline = socket.gettime() + (opts.write_timeout or 30)
    sock:settimeout(POLL_INTERVAL)
    local next_idx = 1
    while true do
        local last, err, partial_last = sock:send(data, next_idx)
        if last then
            if last >= #data then return true end
            next_idx = last + 1
        elseif err == "timeout" then
            if partial_last and partial_last >= next_idx then next_idx = partial_last + 1 end
            if poll_aborted(opts) then return nil, "aborted" end
            if socket.gettime() >= deadline then return nil, "timeout" end
            if opts.yield_callback then opts.yield_callback() end
        else
            return nil, err
        end
    end
end

--- Yieldable line receive. On timeout, receive("*l") drains its buffer into the
--- partial return, so fragments are accumulated until the newline arrives.
--- Returns line, nil on success; nil, err on failure ("closed" may still deliver
--- a final unterminated line as the first return).
local function poll_receive_line(sock, opts)
    local deadline = socket.gettime() + (opts.read_timeout or 30)
    sock:settimeout(POLL_INTERVAL)
    local acc = nil
    while true do
        local line, err, partial = sock:receive("*l")
        if line then
            return acc and (acc .. line) or line
        end
        if partial and #partial > 0 then
            acc = acc and (acc .. partial) or partial
        end
        if err == "timeout" then
            if poll_aborted(opts) then return nil, "aborted" end
            if socket.gettime() >= deadline then return nil, "timeout" end
            if opts.yield_callback then opts.yield_callback() end
        elseif err == "closed" then
            return acc, "closed"
        else
            return nil, err
        end
    end
end

--- Yieldable chunk receive. Returns data (possibly ""), nil+err otherwise
--- ("closed" = EOF, "aborted", or a transport error).
local function poll_receive_chunk(sock, size, opts)
    local deadline = socket.gettime() + (opts.read_timeout or 30)
    sock:settimeout(POLL_INTERVAL)
    while true do
        local chunk, err, partial = sock:receive(size)
        if chunk then
            return chunk
        end
        if partial and #partial > 0 then
            return partial
        end
        if err == "timeout" then
            if poll_aborted(opts) then return nil, "aborted" end
            if socket.gettime() >= deadline then return nil, "timeout" end
            if opts.yield_callback then opts.yield_callback() end
        else
            return nil, err
        end
    end
end

HTTPHop.poll_receive_chunk = poll_receive_chunk

--- Parse a URL into a normalized hop target {scheme, host, port, path}
--- (query folded into path, raw spaces escaped, leading slash ensured).
--- Returns nil if the URL has no host.
function HTTPHop.parseTarget(raw_url)
    local parsed = url_util.parse(raw_url)
    if not parsed or not parsed.host then return nil end
    local scheme = (parsed.scheme or "http"):lower()
    local port = tonumber(parsed.port) or (scheme == "https" and 443 or 80)
    local path = parsed.path or "/"
    if parsed.query then
        path = path .. "?" .. parsed.query
    end
    path = path:gsub(" ", "%%20")
    if not path:match("^/") then
        path = "/" .. path
    end
    return { scheme = scheme, host = parsed.host, port = port, path = path }
end

--- Perform one GET hop over raw_url.
--- opts: { abort_checker, yield_callback, connect_timeout, read_timeout,
---          write_timeout, user_agent }
--- Returns:
---   true, { code, status_msg, headers, client, scheme, host, port }
---     — client positioned at the body start; caller owns closing it
---   false, "aborted"
---   false, { stage = url|connect|ssl_unavailable|ssl_wrap|ssl_handshake|
---             send|status|malformed_status, detail, host, port }
function HTTPHop.performGet(raw_url, opts)
    opts = opts or {}
    local target = HTTPHop.parseTarget(raw_url)
    if not target then
        return false, { stage = "url", detail = tostring(raw_url) }
    end

    local tcp = socket.tcp()
    local conn_ok, conn_err = poll_connect(tcp, target.host, target.port, opts)
    if not conn_ok then
        tcp:close()
        if conn_err == "aborted" then return false, "aborted" end
        return false, { stage = "connect", detail = tostring(conn_err), host = target.host, port = target.port }
    end

    local client = tcp
    if target.scheme == "https" then
        if not ssl then
            tcp:close()
            return false, { stage = "ssl_unavailable", detail = "LuaSec SSL library is unavailable", host = target.host, port = target.port }
        end
        local ssl_sock, ssl_err = ssl.wrap(tcp, { mode = "client", protocol = "any", verify = "none", options = "all" })
        if not ssl_sock then
            tcp:close()
            return false, { stage = "ssl_wrap", detail = tostring(ssl_err), host = target.host, port = target.port }
        end
        client = ssl_sock
        local hs_ok, hs_err = poll_handshake(ssl_sock, opts)
        if not hs_ok then
            client:close()
            if hs_err == "aborted" then return false, "aborted" end
            return false, { stage = "ssl_handshake", detail = tostring(hs_err), host = target.host, port = target.port }
        end
    end

    -- Host header carries the port unless it is the scheme's default
    local host_header = target.host
    if not ((target.scheme == "http" and target.port == 80) or (target.scheme == "https" and target.port == 443)) then
        host_header = string.format("%s:%d", target.host, target.port)
    end

    local request = string.format(
        "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        target.path, host_header, opts.user_agent or "KOReader lanfetch/1.0")

    local send_ok, send_err = poll_send(client, request, opts)
    if not send_ok then
        client:close()
        if send_err == "aborted" then return false, "aborted" end
        return false, { stage = "send", detail = tostring(send_err) }
    end

    local status_line, status_err = poll_receive_line(client, opts)
    if not status_line then
        client:close()
        if status_err == "aborted" then return false, "aborted" end
        return false, { stage = "status", detail = tostring(status_err) }
    end

    status_line = status_line:gsub("[\r\n]+$", "")
    local _, code_str, status_msg = status_line:match("^(HTTP/[%d%.]+)%s+(%d+)%s*(.*)$")
    local code = tonumber(code_str)
    if not code then
        client:close()
        return false, { stage = "malformed_status", detail = status_line }
    end

    local headers = {}
    while true do
        local line, line_err = poll_receive_line(client, opts)
        if not line then
            if line_err == "aborted" then
                client:close()
                return false, "aborted"
            end
            break
        end
        line = line:gsub("[\r\n]+$", "")
        if line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then
            headers[k:lower()] = (v or ""):gsub("%s+$", "")
        end
    end

    return true, {
        code = code,
        status_msg = status_msg,
        headers = headers,
        client = client,
        scheme = target.scheme,
        host = target.host,
        port = target.port,
    }
end

return HTTPHop
