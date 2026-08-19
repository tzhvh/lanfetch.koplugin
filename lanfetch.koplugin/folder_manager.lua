--[[--
FolderManager: Preset management and recursive directory creation for KOReader.
Enforces strict path traversal sanitization to keep all downloads within the base directory.
--]]--

local ok_util, util = pcall(require, "util")
if not ok_util or not util then
    util = {
        makePath = function(path)
            os.execute("mkdir -p " .. string.format("%q", path))
            return true
        end
    }
end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
    if not ok_lfs or not lfs then
        lfs = {
            attributes = function(p)
                local f = io.open(p, "r")
                if f then f:close(); return { mode = "directory" } end
                return nil
            end
        }
    end
end

local FolderManager = {}
FolderManager.__index = FolderManager

local DEFAULT_PRESETS = {
    "Inbox",
    "Articles",
    "Work/Reports",
    "Books/Tech"
}

--- Sanitize subfolder name to strictly prevent directory traversal attacks (e.g. ../../../../etc)
function FolderManager.sanitizeSubfolder(name)
    if not name or type(name) ~= "string" then return "" end
    name = name:gsub("[\r\n\t]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("\\", "/")
    name = name:gsub("%z", "")

    local parts = {}
    for part in name:gmatch("[^/]+") do
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        -- Reject directory traversal tokens: empty, '.', and '..'
        if part ~= "" and part ~= "." and part ~= ".." then
            -- Sanitize illegal filesystem characters (: * ? " < > |)
            part = part:gsub('[:%*%?"<>|]', "_")
            -- Strip leading/trailing dots in folder names to avoid hidden directories
            part = part:gsub("^%.+", ""):gsub("%.+$", "")
            if part ~= "" then
                table.insert(parts, part)
            end
        end
    end
    return table.concat(parts, "/")
end

function FolderManager.new(base_dir, saved_presets, active_subfolder)
    local self = setmetatable({}, FolderManager)
    self.base_dir = base_dir or "/mnt/onboard/documents/Downloads"
    self.base_dir = self.base_dir:gsub("/+$", "")
    
    self.presets = {}
    local raw_presets = saved_presets or DEFAULT_PRESETS
    for _, p in ipairs(raw_presets) do
        local clean = FolderManager.sanitizeSubfolder(p)
        if clean ~= "" then
            table.insert(self.presets, clean)
        end
    end
    
    if #self.presets == 0 then
        for _, p in ipairs(DEFAULT_PRESETS) do
            table.insert(self.presets, p)
        end
    end
    
    self.active_subfolder = FolderManager.sanitizeSubfolder(active_subfolder or self.presets[1] or "")
    return self
end

function FolderManager:getTargetPath()
    local clean_sub = FolderManager.sanitizeSubfolder(self.active_subfolder)
    if clean_sub == "" then
        return self.base_dir
    end
    return self.base_dir .. "/" .. clean_sub
end

function FolderManager:selectPreset(subfolder_name)
    self.active_subfolder = FolderManager.sanitizeSubfolder(subfolder_name)
end

function FolderManager:addPreset(new_subfolder)
    local clean = FolderManager.sanitizeSubfolder(new_subfolder)
    if clean == "" then return end

    for _, p in ipairs(self.presets) do
        if p == clean then
            self.active_subfolder = clean
            return
        end
    end

    table.insert(self.presets, clean)
    self.active_subfolder = clean
end

function FolderManager:removePreset(subfolder_name)
    local clean = FolderManager.sanitizeSubfolder(subfolder_name)
    for i, p in ipairs(self.presets) do
        if p == clean or p == subfolder_name then
            table.remove(self.presets, i)
            if self.active_subfolder == clean or self.active_subfolder == subfolder_name then
                self.active_subfolder = self.presets[1] or ""
            end
            break
        end
    end
end

function FolderManager:setBaseDir(new_base_dir)
    if new_base_dir and new_base_dir ~= "" then
        self.base_dir = new_base_dir:gsub("/+$", "")
    end
end

function FolderManager:getPresetTagItems()
    local items = {}
    table.insert(items, {
        name = "Base Root",
        subfolder = "",
        is_active = (self.active_subfolder == ""),
        display_text = "[Root]"
    })

    for _, p in ipairs(self.presets) do
        table.insert(items, {
            name = p,
            subfolder = p,
            is_active = (self.active_subfolder == p),
            display_text = p
        })
    end

    return items
end

function FolderManager:ensureTargetDirectoryExists()
    local target = self:getTargetPath()
    -- Security assertion: Target path MUST strictly start with base_dir prefix
    if target ~= self.base_dir and target:sub(1, #self.base_dir + 1) ~= (self.base_dir .. "/") then
        return false, "Path traversal security violation"
    end
    local success = util.makePath(target)
    return success, target
end

return FolderManager
