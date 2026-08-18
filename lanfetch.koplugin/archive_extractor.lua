--[[--
ArchiveExtractor: extracts a completed archive download into a subfolder using
KOReader's ffi/archiver (libarchive): Reader:open → iterate entries →
extractToPath per entry, the same pattern as KOReader plugin OTA flows.

The result contract mirrors the DownloadEngine funnel — one uniform table
{ ok = bool, files = n, error = msg|nil, aborted = bool } — and one exit rule:
unless every entry extracted cleanly, the destination directory is removed, so
callers never see a half-extracted tree.

Safety:
  - Entry paths are validated in Lua (no absolute paths, backslashes, or
    ".." segments) on top of libarchive's own ARCHIVE_EXTRACT_SECURE_NODOTDOT
    guard inside Reader:extractToPath, and duplicate entry paths are rejected
    (a duplicate would make the archiver's path-keyed seeking extract the
    wrong entry).
  - Entry count and total uncompressed size are capped against archive bombs.
  - Links, devices, and other non-file/non-directory entry types are skipped.

The archiver implementation is injectable (opts.archiver) so the module runs
headless in tests; on device the default is ffi/archiver, loaded lazily.
--]]--

local ArchiveExtractor = {
    MAX_ENTRIES = 2000,
    MAX_TOTAL_BYTES = 1024 * 1024 * 1024, -- 1 GiB uncompressed
}

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger then
    logger = { dbg = function() end, warn = function() end }
end

local function attributes_of(path)
    if lfs.symlinkattributes then return lfs.symlinkattributes(path) end
    return lfs.attributes(path)
end

local function mkdir_p(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and lfs.attributes(parent, "mode") ~= "directory" then
        if not mkdir_p(parent) then return false end
    end
    return lfs.mkdir(path)
end

-- Never follows symlinks while deleting: a link entry is os.remove'd, a real
-- directory is emptied then removed.
local function rmtree(path)
    local attr = attributes_of(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) ~= nil end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            rmtree(path .. "/" .. name)
        end
    end
    return lfs.rmdir(path)
end

--- True when an archive entry path must not be materialized under the
--- destination: absolute paths, Windows separators or drive letters, and any
--- ".." segment (zip-slip). Exposed for testing.
function ArchiveExtractor.isUnsafeEntryPath(path)
    if type(path) ~= "string" or path == "" then return true end
    if path:find("\\", 1, true) then return true end
    if path:sub(1, 1) == "/" then return true end
    if path:match("^%a:[/\\]") then return true end
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then return true end
    end
    return false
end

--- Extract `archive_path` (a .zip; libarchive also reads tar/7z) into
--- `dest_dir`, creating it and any missing parents. opts:
---   archiver     = table with .Reader (default: lazily required ffi/archiver)
---   abort_checker = fn() → true stops extraction; dest_dir is removed
---   yield_fn      = fn() pumped after every entry to keep the event loop alive
--- Returns { ok, files, error, aborted }.
function ArchiveExtractor.extract(archive_path, dest_dir, opts)
    opts = opts or {}
    if not (lfs and lfs.attributes and lfs.dir and lfs.mkdir) then
        return { ok = false, files = 0, error = "filesystem library unavailable", aborted = false }
    end

    -- An injected archiver owns its own archive handling (tests); the real
    -- path checks the file exists before touching ffi/archiver.
    local Archiver = opts.archiver
    if not Archiver then
        if type(archive_path) ~= "string" or archive_path == ""
            or lfs.attributes(archive_path, "mode") ~= "file" then
            return { ok = false, files = 0, error = "archive not found: " .. tostring(archive_path), aborted = false }
        end
        local ok_a, mod = pcall(require, "ffi/archiver")
        if not ok_a or type(mod) ~= "table" or not mod.Reader then
            return { ok = false, files = 0, error = "ffi/archiver unavailable on this build", aborted = false }
        end
        Archiver = mod
    end

    local files = 0
    local arc = nil
    local seen_paths = {}
    local function fail(error_msg, aborted)
        if arc then arc:close() end
        rmtree(dest_dir)
        return { ok = false, files = files, error = error_msg, aborted = aborted == true }
    end

    arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        return fail("cannot open archive: " .. tostring(arc.err))
    end
    if not mkdir_p(dest_dir) then
        return fail("cannot create directory: " .. tostring(dest_dir))
    end

    local entries_seen = 0
    local total_bytes = 0
    for entry in arc:iterate() do
        entries_seen = entries_seen + 1
        if entries_seen > ArchiveExtractor.MAX_ENTRIES then
            return fail(string.format("archive has too many entries (max %d)", ArchiveExtractor.MAX_ENTRIES))
        end

        local path = entry and entry.path
        if ArchiveExtractor.isUnsafeEntryPath(path) then
            return fail("unsafe entry path: " .. tostring(path))
        end
        if seen_paths[path] then
            return fail("duplicate entry path: " .. path)
        end
        seen_paths[path] = true

        if entry.mode == "directory" then
            if not mkdir_p(dest_dir .. "/" .. path) then
                return fail("cannot create directory: " .. path)
            end
        elseif entry.mode == "file" then
            total_bytes = total_bytes + (tonumber(entry.size) or 0)
            if total_bytes > ArchiveExtractor.MAX_TOTAL_BYTES then
                return fail(string.format("archive exceeds %d bytes uncompressed", ArchiveExtractor.MAX_TOTAL_BYTES))
            end
            local dest_path = dest_dir .. "/" .. path
            local parent = dest_path:match("^(.*)/[^/]+$")
            if parent and parent ~= dest_dir and not mkdir_p(parent) then
                return fail("cannot create directory: " .. parent)
            end
            if not arc:extractToPath(path, dest_path) then
                return fail("failed to extract " .. path .. (arc.err and (": " .. tostring(arc.err)) or ""))
            end
            files = files + 1
        else
            -- links, devices, sockets, fifos: never materialized
            logger.dbg("ArchiveExtractor: skipping entry " .. path .. " (" .. tostring(entry.mode) .. ")")
        end

        -- Abort before every yield, the same contract as the http_hop transport
        if opts.abort_checker and opts.abort_checker() then
            return fail("canceled", true)
        end
        if opts.yield_fn then opts.yield_fn() end
    end
    arc:close()
    arc = nil

    if entries_seen == 0 then
        return fail("archive is empty or unreadable")
    end
    return { ok = true, files = files, error = nil, aborted = false }
end

return ArchiveExtractor
