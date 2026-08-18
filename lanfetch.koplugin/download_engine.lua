--[[--
DownloadEngine: Resilient HTTP/HTTPS streaming download engine for KOReader.
Handles non-standard LAN HTTP servers (e.g. ShareViaHttp, Python http.server, Calibre),
RFC 5987 Content-Disposition parsing, unencoded redirect paths with spaces,
pre-download filename derivation from redirects, and atomic direct-to-disk streaming without memory buffering.
Every network hop runs through http_hop's yieldable poll transport, so
cancellation lands within one poll interval even during connect or TLS
handshake, and the KOReader event loop keeps pumping.
--]]--

local socket = require("socket")
local url_util = require("socket.url")
local http_hop = require("http_hop")

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

local ok_dev, Device = pcall(require, "device")

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

--- Terminal outcome kinds. Every download() exit returns a uniform table:
---   { kind = KIND.COMPLETED, path = <final path>,  meta = {url,size,filename,content_type}, error = nil }
---   { kind = KIND.ABORTED,   path = nil,           meta = {},                                      error = nil }
---   { kind = KIND.FAILED,    path = nil,           meta = {},                                      error = <message> }
--- meta is always a table and error is nil exactly when kind ~= FAILED, so callers
--- never test for field presence.
DownloadEngine.KIND = {
    COMPLETED = "completed",
    ABORTED = "aborted",
    FAILED = "failed",
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

--- Removes orphaned .lanfetch_*.tmp partial files left behind by crashes
--- mid-download. Returns the number of files removed.
function DownloadEngine.sweepOrphanTempFiles(target_dir)
    if not lfs or not lfs.dir then return 0 end
    local removed = 0
    for entry in lfs.dir(target_dir) do
        if entry:match("^%.lanfetch_%d+_%d+%.tmp$") then
            if os.remove(target_dir .. "/" .. entry) then
                removed = removed + 1
            end
        end
    end
    return removed
end

--- Lightweight pre-flight probe: Follows redirects to derive filename and file size
--- before download prompt. One yieldable http_hop per attempt: abort_checker is
--- polled before every yield, so CANCEL lands mid-connect, not just between hops.
--- Returns (name_or_nil, final_url, size_or_nil, headers_or_nil); network failures
--- never throw, they degrade to nil results for the caller to soft-handle.
function DownloadEngine.probeRemoteMetadata(initial_url, timeout_sec, abort_checker, yield_callback)
    timeout_sec = timeout_sec or 5
    local hop_opts = {
        abort_checker = abort_checker,
        yield_callback = yield_callback,
        connect_timeout = timeout_sec,
        read_timeout = timeout_sec,
        write_timeout = timeout_sec,
        user_agent = "KOReader/Downloader",
    }
    local current_url = initial_url
    local redirect_count = 0
    local visited_urls = {}
    local last_location_name = nil

    while redirect_count < DownloadEngine.MAX_REDIRECTS do
        if visited_urls[current_url] then break end
        visited_urls[current_url] = true

        local ok, res = http_hop.performGet(current_url, hop_opts)
        if not ok then break end -- any failure, including abort, soft-degrades

        res.client:close()
        local code = res.code
        local headers = res.headers

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

----- Resilient Download: redirect policy, protocol fallback, streaming, atomic
----- finalization — one yieldable http_hop per attempt
function DownloadEngine.download(initial_url, target_directory, options, progress_callback, abort_checker, yield_callback)
    local KIND = DownloadEngine.KIND
    options = options or {}
    local model_name = "KOReader"
    if ok_dev and Device and Device.getModel then
        pcall(function() model_name = Device:getModel() end)
    end
    local hop_opts = {
        abort_checker = abort_checker,
        yield_callback = yield_callback,
        connect_timeout = DownloadEngine.CONNECT_TIMEOUT,
        read_timeout = DownloadEngine.READ_TIMEOUT,
        write_timeout = DownloadEngine.READ_TIMEOUT,
        user_agent = string.format("KOReader lanfetch/%s (%s)", "1.0", tostring(model_name)),
    }
    local current_url = initial_url
    local redirect_count = 0
    local visited_urls = {}
    local attempted_protocol_fallback = false

    -- Terminal funnel: the single exit path from this function. Closes the live
    -- socket and removes the partial temp file unless the download completed.
    local open_client = nil
    local part_path = nil
    local function finish(outcome_kind, path, meta, error_msg)
        if open_client then
            open_client:close()
            open_client = nil
        end
        if part_path and outcome_kind ~= KIND.COMPLETED then
            os.remove(part_path)
            part_path = nil
        end
        return { kind = outcome_kind, path = path, meta = meta or {}, error = error_msg }
    end

    while true do
        if abort_checker and abort_checker() then
            return finish(KIND.ABORTED)
        end

        if redirect_count > DownloadEngine.MAX_REDIRECTS then
            return finish(KIND.FAILED, nil, nil, _("Too many redirects (max 10)"))
        end

        if visited_urls[current_url] then
            return finish(KIND.FAILED, nil, nil, _("Circular redirect loop detected: ") .. current_url)
        end
        visited_urls[current_url] = true

        local hop_ok, res = http_hop.performGet(current_url, hop_opts)

        if not hop_ok then
            if res == "aborted" then
                return finish(KIND.ABORTED)
            end
            local stage, detail = res.stage, res.detail
            if stage == "url" then
                return finish(KIND.FAILED, nil, nil, _("Invalid URL: ") .. tostring(detail))
            elseif stage == "connect" then
                -- Transparent HTTP -> HTTPS fallback (connect failures only)
                if not attempted_protocol_fallback and current_url:match("^http://") then
                    attempted_protocol_fallback = true
                    current_url = current_url:gsub("^http://", "https://")
                    logger.warn("DownloadEngine: HTTP connect failed. Retrying HTTPS: " .. current_url)
                    visited_urls = {}
                else
                    return finish(KIND.FAILED, nil, nil,
                        T(_("Connection failed to %1:%2 (%3)"), res.host, res.port, tostring(detail)))
                end
            elseif stage == "ssl_unavailable" then
                return finish(KIND.FAILED, nil, nil, _("HTTPS requested but ") .. tostring(detail))
            elseif stage == "ssl_wrap" then
                return finish(KIND.FAILED, nil, nil, _("SSL wrap failed: ") .. tostring(detail))
            elseif stage == "ssl_handshake" then
                return finish(KIND.FAILED, nil, nil, _("SSL handshake failed: ") .. tostring(detail))
            elseif stage == "send" then
                return finish(KIND.FAILED, nil, nil, _("Failed to send request: ") .. tostring(detail))
            elseif stage == "status" then
                return finish(KIND.FAILED, nil, nil, _("Server closed connection without response: ") .. tostring(detail))
            elseif stage == "malformed_status" then
                return finish(KIND.FAILED, nil, nil, _("Malformed HTTP status line: ") .. tostring(detail))
            else
                return finish(KIND.FAILED, nil, nil, tostring(detail))
            end
        else
            local client = res.client
            open_client = client
            local code = res.code
            local headers = res.headers

            logger.dbg(string.format("DownloadEngine: Response %d for %s", code, current_url))

            -- Step A: Handle 30x Redirects (close immediately, ignore Content-Length on 30x)
            if code >= 300 and code < 400 and headers["location"] then
                client:close()
                open_client = nil
                local raw_loc = headers["location"]
                local loc_escaped = raw_loc:gsub(" ", "%%20")
                current_url = url_util.absolute(current_url, loc_escaped)
                redirect_count = redirect_count + 1

            -- Step B: Handle 200 OK Body Streaming
            elseif code >= 200 and code < 300 then
                local total_expected_bytes = tonumber(headers["content-length"]) or 0

                -- Open temporary destination file
                local tmp_filename = string.format(".lanfetch_%d_%d.tmp", os.time(), math.random(1000, 9999))
                part_path = target_directory .. "/" .. tmp_filename
                local file_handle, io_err = io.open(part_path, "wb")
                if not file_handle then
                    part_path = nil
                    return finish(KIND.FAILED, nil, nil, _("Cannot create file in destination: ") .. tostring(io_err))
                end

                local bytes_received = 0
                local download_start_time = socket.gettime()

                -- Stream chunks directly to disk
                while true do
                    if abort_checker and abort_checker() then
                        file_handle:close()
                        return finish(KIND.ABORTED)
                    end

                    local data, stream_err = http_hop.poll_receive_chunk(client, 8192, hop_opts)
                    if data then
                        if #data > 0 then
                            file_handle:write(data)
                            bytes_received = bytes_received + #data
                            if progress_callback then
                                local elapsed = math.max(0.001, socket.gettime() - download_start_time)
                                local speed_bps = bytes_received / elapsed
                                local percentage = (total_expected_bytes > 0) and ((bytes_received / total_expected_bytes) * 100) or 0
                                local cont = progress_callback(bytes_received, total_expected_bytes, percentage, speed_bps)
                                if cont == false then
                                    file_handle:close()
                                    return finish(KIND.ABORTED)
                                end
                            end
                        end
                        -- Pump the event loop per chunk even when data flows fast
                        -- enough that no poll timeout fired inside the hop.
                        if yield_callback then
                            yield_callback()
                        end
                    elseif stream_err == "closed" then
                        break
                    elseif stream_err == "aborted" then
                        file_handle:close()
                        return finish(KIND.ABORTED)
                    else
                        file_handle:close()
                        return finish(KIND.FAILED, nil, nil, T(_("Download interrupted (%1)"), tostring(stream_err)))
                    end
                end

                file_handle:close()
                client:close()
                open_client = nil

                if bytes_received == 0 then
                    return finish(KIND.FAILED, nil, nil, _("Downloaded file is empty (0 bytes)"))
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
                    return finish(KIND.FAILED, nil, nil, _("Failed to finalize file: ") .. tostring(rename_err))
                end
                part_path = nil

                local metadata = {
                    url = current_url,
                    size = bytes_received,
                    filename = sanitized_name,
                    content_type = headers["content-type"],
                }
                return finish(KIND.COMPLETED, final_path, metadata)

            -- Step C: Handle HTTP 400 fallback or errors
            elseif code == 400 and not attempted_protocol_fallback and res.scheme == "http" then
                client:close()
                open_client = nil
                attempted_protocol_fallback = true
                current_url = current_url:gsub("^http://", "https://")
                logger.warn("DownloadEngine: HTTP 400. Retrying HTTPS: " .. current_url)
                visited_urls = {}

            else
                return finish(KIND.FAILED, nil, nil, T(_("Server returned HTTP %1 (%2)"), code, tostring(res.status_msg or "")))
            end
        end
    end
end

return DownloadEngine
