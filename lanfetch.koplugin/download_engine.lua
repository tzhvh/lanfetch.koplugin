--[[--
DownloadEngine: Resilient HTTP/HTTPS streaming download engine for KOReader.
Handles non-standard LAN HTTP servers (e.g. ShareViaHttp, Python http.server, Calibre),
RFC 5987 Content-Disposition parsing, unencoded redirect paths with spaces,
pre-download filename derivation from redirects, and atomic direct-to-disk streaming without memory buffering.
--]]--

local socket = require("socket")
local ssl = pcall(require, "ssl") and require("ssl") or nil
local url_util = require("socket.url")

local ok_su, socketutil = pcall(require, "socketutil")
if not ok_su or not socketutil then
    socketutil = { set_timeout = function(...) end }
end

local ok_trap, Trapper = pcall(require, "ui/trapper")
if not ok_trap or not Trapper then
    Trapper = { wrap = function(fn) return fn() end }
end

local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger then
    logger = { dbg = function(...) end, warn = function(...) end, error = function(...) end, info = function(...) end }
end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
    if not ok_lfs or not lfs then
        lfs = { attributes = function(p) local f = io.open(p, "r"); if f then f:close(); return { mode = "file" } end; return nil end }
    end
end

local ok_gettext, _ = pcall(require, "gettext")
if not ok_gettext or type(_) ~= "function" then
    _ = function(msg) return msg end
end

local ok_util, T_mod = pcall(require, "ffi/util")
local T = (ok_util and T_mod and T_mod.template) or function(tmpl, ...)
    local args = { ... }
    return tmpl:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end)
end

local DownloadEngine = {
    MAX_REDIRECTS = 10,
    CONNECT_TIMEOUT = 10,
    READ_TIMEOUT = 30,
}

--- Parse Content-Disposition header conforming to RFC 6266 & RFC 5987
function DownloadEngine.parseContentDisposition(header_val)
    if not header_val or header_val == "" then return nil end

    -- 1. RFC 5987 / RFC 6266 extended syntax: filename*=UTF-8''my%20file.pdf
    local charset, lang, encoded = header_val:match("filename%*%s*=%s*([^']*)'([^']*)'([^;%s]+)")
    if not encoded then
        charset, lang, encoded = header_val:match("filename%*%s*=%s*\"?([^'\"]*)'([^'\"]*)'([^;\"]+)\"?")
    end
    if encoded and encoded ~= "" then
        local ok, decoded = pcall(url_util.unescape, encoded)
        if ok and decoded and decoded ~= "" then
            return decoded
        end
    end

    -- 2. Standard quoted: filename="document.pdf"
    local quoted = header_val:match('filename%s*=%s*"([^"]+)"')
    if quoted and quoted ~= "" then
        return quoted
    end

    -- 3. Standard unquoted: filename=document.pdf
    local token = header_val:match("filename%s*=%s*([^;%s]+)")
    if token and token ~= "" then
        return token:gsub("^'", ""):gsub("'$", "")
    end

    return nil
end

--- Extract filename from URL path segment as fallback
function DownloadEngine.extractFilenameFromUrl(url_str)
    local parsed = url_util.parse(url_str)
    if not parsed or not parsed.path then return nil end
    local path_filename = parsed.path:match("([^/]+)$")
    if path_filename and path_filename ~= "" then
        local ok, decoded = pcall(url_util.unescape, path_filename)
        if ok and decoded and decoded ~= "" then
            return decoded
        end
    end
    return nil
end

--- Sanitize filename for safe storage on FAT32/Linux/Android filesystems
function DownloadEngine.sanitizeFilename(filename, fallback_name)
    fallback_name = fallback_name or "download.pdf"
    if not filename or filename == "" then
        filename = fallback_name
    end

    filename = filename:gsub("\\", "/")
    filename = filename:match("([^/]+)$") or filename

    -- Replace illegal FAT32/Android characters (< > : " / \ | ? * and control chars)
    filename = filename:gsub("[%z\1-\31<>:\"/\\|%?%*]", "_")

    -- Strip leading/trailing dots and spaces
    filename = filename:gsub("^[%.%s]+", ""):gsub("[%.%s]+$", "")

    local name_stem = filename:match("^(.-)%.[^%.]+$") or filename
    local reserved = {
        CON=true, PRN=true, AUX=true, NUL=true,
        COM1=true, COM2=true, COM3=true, COM4=true, COM5=true, COM6=true, COM7=true, COM8=true, COM9=true,
        LPT1=true, LPT2=true, LPT3=true, LPT4=true, LPT5=true, LPT6=true, LPT7=true, LPT8=true, LPT9=true,
    }
    if reserved[name_stem:upper()] then
        filename = "_" .. filename
    end

    if filename == "" then
        filename = fallback_name
    end

    if not filename:lower():match("%.pdf$") then
        filename = filename .. ".pdf"
    end

    if #filename > 200 then
        local ext = filename:match("(%.[^%.]+)$") or ".pdf"
        local stem = filename:sub(1, 200 - #ext)
        filename = stem .. ext
    end

    return filename
end

--- Generates a non-colliding filename candidate
function DownloadEngine.getUniqueFilename(target_dir, base_name)
    local path = target_dir .. "/" .. base_name
    if not lfs.attributes(path) then return base_name end

    local name_part, ext = base_name:match("^(.-)(%.[^%.]+)$")
    name_part = name_part or base_name
    ext = ext or ""

    local index = 1
    while true do
        local candidate = string.format("%s (%d)%s", name_part, index, ext)
        if not lfs.attributes(target_dir .. "/" .. candidate) then
            return candidate
        end
        index = index + 1
    end
end

--- Lightweight pre-flight probe: Follows redirects to derive filename and file size before download prompt
function DownloadEngine.probeRemoteMetadata(initial_url, timeout_sec)
    timeout_sec = timeout_sec or 5
    local current_url = initial_url
    local redirect_count = 0
    local visited_urls = {}
    local last_location_name = nil

    while redirect_count < DownloadEngine.MAX_REDIRECTS do
        if visited_urls[current_url] then break end
        visited_urls[current_url] = true

        local parsed = url_util.parse(current_url)
        if not parsed or not parsed.host then break end

        local scheme = (parsed.scheme or "http"):lower()
        local host = parsed.host
        local port = tonumber(parsed.port) or (scheme == "https" and 443 or 80)
        local path = parsed.path or "/"
        if parsed.query then path = path .. "?" .. parsed.query end
        path = path:gsub(" ", "%%20")
        if not path:match("^/") then path = "/" .. path end

        local tcp = socket.tcp()
        tcp:settimeout(timeout_sec)
        local ok, err = tcp:connect(host, port)
        if not ok then
            tcp:close()
            break
        end

        local client = tcp
        if scheme == "https" then
            if not ssl then tcp:close(); break end
            local ssl_sock = ssl.wrap(tcp, { mode = "client", protocol = "any", verify = "none", options = "all" })
            if not ssl_sock then tcp:close(); break end
            if not ssl_sock:dohandshake() then ssl_sock:close(); break end
            client = ssl_sock
        end

        client:settimeout(timeout_sec)

        local host_header = (port == 80 or port == 443) and host or string.format("%s:%d", host, port)
        local req = string.format("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: KOReader/Downloader\r\nAccept: */*\r\nConnection: close\r\n\r\n", path, host_header)
        client:send(req)

        local status_line = client:receive("*l")
        if not status_line then
            client:close()
            break
        end

        local http_ver, code_str = status_line:match("^(HTTP/[%d%.]+)%s+(%d+)")
        local code = tonumber(code_str) or 0

        local headers = {}
        while true do
            local line = client:receive("*l")
            if not line or line == "" then break end
            local hk, hv = line:match("^([^:]+):%s*(.*)$")
            if hk then headers[hk:lower()] = hv end
        end
        client:close()

        if code >= 300 and code < 400 and headers["location"] then
            local raw_loc = headers["location"]
            local loc_filename = raw_loc:match("([^/]+)$")
            if loc_filename and loc_filename ~= "" then
                local ok_un, decoded = pcall(url_util.unescape, loc_filename)
                if ok_un and decoded and decoded ~= "" then
                    last_location_name = decoded
                end
            end
            local loc_escaped = raw_loc:gsub(" ", "%%20")
            current_url = url_util.absolute(current_url, loc_escaped)
            redirect_count = redirect_count + 1
        elseif code >= 200 and code < 300 then
            local cd_name = DownloadEngine.parseContentDisposition(headers["content-disposition"])
            local url_name = DownloadEngine.extractFilenameFromUrl(current_url)
            local final_name = cd_name or url_name or last_location_name
            local size = tonumber(headers["content-length"])
            return final_name, current_url, size, headers
        else
            break
        end
    end

    local fallback_url_name = DownloadEngine.extractFilenameFromUrl(current_url)
    return fallback_url_name or last_location_name, current_url, nil, nil
end

--- Resilient Socket Transport: Handles HTTP/HTTPS, redirects with raw spaces & broken 302 Content-Lengths
function DownloadEngine.download(initial_url, target_directory, options, progress_callback, abort_checker)
    options = options or {}
    local current_url = initial_url
    local redirect_count = 0
    local visited_urls = {}
    local attempted_protocol_fallback = false

    local success = false
    local result_path_or_err = nil
    local metadata = {}

    Trapper:wrap(function()
        socketutil:set_timeout(DownloadEngine.CONNECT_TIMEOUT, DownloadEngine.READ_TIMEOUT)

        local ok, run_err = pcall(function()
            while true do
                if abort_checker and abort_checker() then
                    error("aborted")
                end

                if redirect_count > DownloadEngine.MAX_REDIRECTS then
                    error(_("Too many redirects (max 10)"))
                end

                if visited_urls[current_url] then
                    error(_("Circular redirect loop detected: ") .. current_url)
                end
                visited_urls[current_url] = true

                -- Parse current URL
                local parsed = url_util.parse(current_url)
                if not parsed or not parsed.host then
                    error(_("Invalid URL: ") .. tostring(current_url))
                end

                local scheme = (parsed.scheme or "http"):lower()
                local host = parsed.host
                local port = tonumber(parsed.port) or (scheme == "https" and 443 or 80)
                local path = parsed.path or "/"
                if parsed.query then
                    path = path .. "?" .. parsed.query
                end

                -- Auto-escape raw spaces and special characters in path
                path = path:gsub(" ", "%%20")
                if not path:match("^/") then
                    path = "/" .. path
                end

                -- Establish TCP connection
                local tcp = socket.tcp()
                tcp:settimeout(DownloadEngine.CONNECT_TIMEOUT)
                local conn_ok, conn_err = tcp:connect(host, port)

                if not conn_ok then
                    tcp:close()
                    -- Transparent HTTP -> HTTPS fallback
                    if not attempted_protocol_fallback and scheme == "http" then
                        attempted_protocol_fallback = true
                        current_url = current_url:gsub("^http://", "https://")
                        logger.warn("DownloadEngine: HTTP connect failed. Retrying HTTPS: " .. current_url)
                        visited_urls = {}
                        -- Loop to retry with HTTPS
                    else
                        error(T(_("Connection failed to %1:%2 (%3)"), host, port, tostring(conn_err)))
                    end
                else
                    local client = tcp
                    -- Wrap TLS if HTTPS
                    if scheme == "https" then
                        if not ssl then
                            tcp:close()
                            error(_("HTTPS requested but LuaSec SSL library is unavailable"))
                        end
                        local ssl_params = {
                            mode = "client",
                            protocol = "any",
                            verify = "none",
                            options = "all",
                        }
                        local ssl_sock, ssl_err = ssl.wrap(tcp, ssl_params)
                        if not ssl_sock then
                            tcp:close()
                            error(_("SSL wrap failed: ") .. tostring(ssl_err))
                        end
                        local handshake_ok, handshake_err = ssl_sock:dohandshake()
                        if not handshake_ok then
                            ssl_sock:close()
                            error(_("SSL handshake failed: ") .. tostring(handshake_err))
                        end
                        client = ssl_sock
                    end

                    client:settimeout(DownloadEngine.READ_TIMEOUT)

                    -- Send HTTP Request
                    local host_header = (port == 80 or port == 443) and host or string.format("%s:%d", host, port)
                    local req = string.format(
                        "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: KOReader/Downloader\r\nAccept: application/pdf,application/octet-stream,*/*\r\nConnection: close\r\n\r\n",
                        path, host_header
                    )
                    client:send(req)

                    -- Read HTTP Status Line
                    local status_line, read_err = client:receive("*l")
                    if not status_line then
                        client:close()
                        error(T(_("Server closed connection without response (%1)"), tostring(read_err)))
                    end

                    local http_ver, code_str, status_msg = status_line:match("^(HTTP/[%d%.]+)%s+(%d+)%s*(.*)$")
                    local code = tonumber(code_str) or 0

                    -- Read Response Headers
                    local headers = {}
                    while true do
                        local header_line, h_err = client:receive("*l")
                        if not header_line or header_line == "" then break end
                        local hk, hv = header_line:match("^([^:]+):%s*(.*)$")
                        if hk then
                            headers[hk:lower()] = hv
                        end
                    end

                    logger.dbg(string.format("DownloadEngine: Response %d for %s", code, current_url))

                    -- Step A: Handle 30x Redirects (301, 302, 303, 307, 308)
                    if code >= 300 and code < 400 then
                        -- Critical fix: Close socket IMMEDIATELY without reading body
                        -- (Ignores buggy Content-Length headers on redirects from ShareViaHttp / Android servers)
                        client:close()

                        local location = headers["location"]
                        if not location or location == "" then
                            error(T(_("HTTP %1 redirect missing Location header"), code))
                        end

                        -- URL-encode unescaped spaces in redirect Location
                        location = location:gsub(" ", "%%20")
                        local target_url = url_util.absolute(current_url, location)
                        logger.dbg("DownloadEngine: Following redirect -> " .. target_url)

                        current_url = target_url
                        redirect_count = redirect_count + 1

                    -- Step B: Handle 200 OK / 206 Partial Content
                    elseif code >= 200 and code < 300 then
                        local total_expected_bytes = tonumber(headers["content-length"]) or 0

                        -- Open temporary destination file
                        local tmp_filename = string.format(".lanfetch_%d_%d.tmp", os.time(), math.random(1000, 9999))
                        local part_path = target_directory .. "/" .. tmp_filename
                        local file_handle, io_err = io.open(part_path, "wb")
                        if not file_handle then
                            client:close()
                            error(_("Cannot create file in destination: ") .. tostring(io_err))
                        end

                        local bytes_received = 0
                        local download_start_time = socket.gettime()

                        -- Stream chunks directly to disk
                        while true do
                            if abort_checker and abort_checker() then
                                file_handle:close()
                                client:close()
                                os.remove(part_path)
                                error("aborted")
                            end

                            local chunk, stream_err, partial = client:receive(8192)
                            local data = chunk or partial
                            if data and #data > 0 then
                                file_handle:write(data)
                                bytes_received = bytes_received + #data
                                if progress_callback then
                                    local elapsed = math.max(0.001, socket.gettime() - download_start_time)
                                    local speed_bps = bytes_received / elapsed
                                    local percentage = (total_expected_bytes > 0) and ((bytes_received / total_expected_bytes) * 100) or 0
                                    local cont = progress_callback(bytes_received, total_expected_bytes, percentage, speed_bps)
                                    if cont == false then
                                        file_handle:close()
                                        client:close()
                                        os.remove(part_path)
                                        error("aborted")
                                    end
                                end
                            end

                            if stream_err == "closed" then
                                break
                            elseif stream_err then
                                file_handle:close()
                                client:close()
                                os.remove(part_path)
                                error(T(_("Download interrupted (%1)"), tostring(stream_err)))
                            end
                        end

                        file_handle:close()
                        client:close()

                        if bytes_received == 0 then
                            os.remove(part_path)
                            error(_("Downloaded file is empty (0 bytes)"))
                        end

                        -- Resolve and sanitize final filename
                        local raw_filename = options.custom_filename
                        if not raw_filename or raw_filename == "" then
                            raw_filename = DownloadEngine.parseContentDisposition(headers["content-disposition"])
                        end
                        if not raw_filename or raw_filename == "" then
                            raw_filename = DownloadEngine.extractFilenameFromUrl(current_url)
                        end

                        local sanitized_name = DownloadEngine.sanitizeFilename(raw_filename)
                        local final_path = target_directory .. "/" .. sanitized_name

                        if not options.overwrite and lfs.attributes(final_path) then
                            sanitized_name = DownloadEngine.getUniqueFilename(target_directory, sanitized_name)
                            final_path = target_directory .. "/" .. sanitized_name
                        end

                        local rename_ok, rename_err = os.rename(part_path, final_path)
                        if not rename_ok then
                            os.remove(part_path)
                            error(_("Failed to finalize file: ") .. tostring(rename_err))
                        end

                        success = true
                        result_path_or_err = final_path
                        metadata = {
                            url = current_url,
                            size = bytes_received,
                            filename = sanitized_name,
                            content_type = headers["content-type"],
                        }
                        return

                    -- Step C: Handle HTTP 400 fallback or errors
                    elseif code == 400 and not attempted_protocol_fallback and scheme == "http" then
                        client:close()
                        attempted_protocol_fallback = true
                        current_url = current_url:gsub("^http://", "https://")
                        logger.warn("DownloadEngine: HTTP 400. Retrying HTTPS: " .. current_url)
                        visited_urls = {}

                    else
                        client:close()
                        error(T(_("Server returned HTTP %1 (%2)"), code, tostring(status_msg or "")))
                    end
                end
            end
        end)

        socketutil:reset_timeout()

        if not ok then
            success = false
            result_path_or_err = tostring(run_err)
        end
    end)

    return success, result_path_or_err, metadata
end

return DownloadEngine
