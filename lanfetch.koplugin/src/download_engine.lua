--[[--
DownloadEngine: Resilient HTTP/HTTPS streaming download engine for KOReader.
Handles cross-protocol redirects, Content-Disposition extraction,
atomic direct-to-disk streaming via ltn12, socketutil timeouts, and Trapper.
--]]--

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local url_util = require("socket.url")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

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

--- Performs a single HTTP/HTTPS request
function DownloadEngine._performRequest(req_url, method, sink, custom_headers)
    local parsed = url_util.parse(req_url)
    if not parsed or not parsed.scheme then
        return nil, nil, _("Invalid URL: ") .. tostring(req_url)
    end

    local scheme = parsed.scheme:lower()
    local request_fn
    if scheme == "http" then
        request_fn = http.request
    elseif scheme == "https" then
        request_fn = https.request
    else
        return nil, nil, _("Unsupported URL scheme: ") .. tostring(scheme)
    end

    local req_headers = {
        ["User-Agent"] = "KOReader/Downloader",
        ["Accept"] = "application/pdf,application/octet-stream,*/*",
        ["Connection"] = "close",
    }
    if custom_headers then
        for k, v in pairs(custom_headers) do
            req_headers[k] = v
        end
    end

    local req_table = {
        url = req_url,
        method = method or "GET",
        headers = req_headers,
        sink = sink,
        redirect = false,
        mode = "client",
        protocol = "any",
        verify = "none",
        options = "all",
    }

    local ok, status_code, resp_headers, status_line = pcall(function()
        return socket.skip(1, request_fn(req_table))
    end)

    if not ok then
        return nil, nil, _("Socket error: ") .. tostring(status_code)
    end

    return tonumber(status_code), resp_headers, status_line
end

--- Execute streaming download pipeline with redirect loop and fallbacks
function DownloadEngine.download(initial_url, target_directory, options, progress_callback, abort_checker)
    options = options or {}
    local current_url = initial_url
    local current_method = "GET"
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

                local tmp_filename = string.format(".lanfetch_%d_%d.tmp", os.time(), math.random(1000, 9999))
                local part_path = target_directory .. "/" .. tmp_filename
                local file_handle, io_err = io.open(part_path, "wb")
                if not file_handle then
                    error(_("Cannot create file in destination: ") .. tostring(io_err))
                end

                local base_file_sink = ltn12.sink.file(file_handle)
                local bytes_received = 0
                local total_expected_bytes = 0

                local wrapped_sink = function(chunk, sink_err)
                    if abort_checker and abort_checker() then
                        return nil, "aborted"
                    end
                    if chunk then
                        bytes_received = bytes_received + #chunk
                        if progress_callback then
                            local cont = progress_callback(bytes_received, total_expected_bytes)
                            if cont == false then
                                return nil, "aborted"
                            end
                        end
                    end
                    return base_file_sink(chunk, sink_err)
                end

                logger.dbg("DownloadEngine: Fetching [", current_method, "] ", current_url)
                local code, headers, status_line = DownloadEngine._performRequest(
                    current_url, current_method, wrapped_sink, options.headers
                )

                pcall(function() file_handle:close() end)

                if headers and (headers["content-length"] or headers["Content-Length"]) then
                    total_expected_bytes = tonumber(headers["content-length"] or headers["Content-Length"]) or 0
                end

                -- Network/Connection failure -> Try protocol fallback
                if not code then
                    os.remove(part_path)
                    local err_msg = tostring(status_line or _("Connection failed"))

                    if not attempted_protocol_fallback and current_url:match("^http://") then
                        attempted_protocol_fallback = true
                        local https_url = current_url:gsub("^http://", "https://")
                        logger.warn("DownloadEngine: HTTP failed. Retrying HTTPS: " .. https_url)
                        current_url = https_url
                        visited_urls = {}
                    else
                        error(err_msg)
                    end

                elseif code == 400 and not attempted_protocol_fallback and current_url:match("^http://") then
                    os.remove(part_path)
                    attempted_protocol_fallback = true
                    local https_url = current_url:gsub("^http://", "https://")
                    logger.warn("DownloadEngine: HTTP 400. Retrying HTTPS: " .. https_url)
                    current_url = https_url
                    visited_urls = {}

                -- 30x Redirects
                elseif code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
                    os.remove(part_path)
                    local location = headers and (headers.location or headers.Location)
                    if not location or location == "" then
                        error(T(_("HTTP %1 redirect missing Location header"), code))
                    end

                    local target_url = url_util.absolute(current_url, location)
                    logger.dbg("DownloadEngine: Redirect -> ", target_url)

                    if code == 303 or ((code == 301 or code == 302) and current_method ~= "HEAD") then
                        current_method = "GET"
                    end

                    current_url = target_url
                    redirect_count = redirect_count + 1

                -- 200 OK / 206 Partial Content
                elseif code == 200 or code == 206 then
                    if bytes_received == 0 then
                        os.remove(part_path)
                        error(_("Downloaded file is empty (0 bytes)"))
                    end

                    local raw_filename = options.custom_filename
                    if not raw_filename or raw_filename == "" then
                        local disposition = headers and (headers["content-disposition"] or headers["Content-Disposition"])
                        raw_filename = DownloadEngine.parseContentDisposition(disposition)
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
                        content_type = headers and (headers["content-type"] or headers["Content-Type"]),
                    }
                    return

                else
                    os.remove(part_path)
                    error(T(_("Server returned HTTP %1 (%2)"), code, tostring(status_line or "")))
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
