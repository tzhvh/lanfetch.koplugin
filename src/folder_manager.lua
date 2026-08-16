-- src/folder_manager.lua
-- Hierarchical Folder Manager & Tag Presets for KOReader LAN PDF Downloader

local FolderManager = {}
FolderManager.__index = FolderManager

local DEFAULT_PRESETS = {
    "Inbox",
    "Articles",
    "Work/Reports",
    "Books/Tech"
}

function FolderManager.new(base_dir, saved_presets, active_subfolder)
    local self = setmetatable({}, FolderManager)
    self.base_dir = base_dir or "/mnt/onboard/documents/Downloads"
    -- Strip trailing slash from base_dir
    self.base_dir = self.base_dir:gsub("/+$", "")
    
    self.presets = saved_presets or {}
    if #self.presets == 0 then
        for _, p in ipairs(DEFAULT_PRESETS) do
            table.insert(self.presets, p)
        end
    end
    
    self.active_subfolder = active_subfolder or self.presets[1] or ""
    return self
end

--- Get the full resolved filesystem target path
function FolderManager:getTargetPath()
    if not self.active_subfolder or self.active_subfolder == "" then
        return self.base_dir
    end
    -- Clean leading/trailing slashes
    local clean_sub = self.active_subfolder:gsub("^/+", ""):gsub("/+$", "")
    return self.base_dir .. "/" .. clean_sub
end

--- Select an existing preset tag
function FolderManager:selectPreset(subfolder_name)
    self.active_subfolder = subfolder_name or ""
end

--- Add a new preset tag (supports nested paths like "Papers/2026/AI")
function FolderManager:addPreset(new_subfolder)
    if not new_subfolder or new_subfolder == "" then return end
    local clean = new_subfolder:gsub("^/+", ""):gsub("/+$", "")
    if clean == "" then return end

    -- Avoid duplicates
    for _, p in ipairs(self.presets) do
        if p == clean then
            self.active_subfolder = clean
            return
        end
    end

    table.insert(self.presets, clean)
    self.active_subfolder = clean
end

--- Remove a preset tag
function FolderManager:removePreset(subfolder_name)
    for i, p in ipairs(self.presets) do
        if p == subfolder_name then
            table.remove(self.presets, i)
            if self.active_subfolder == subfolder_name then
                self.active_subfolder = self.presets[1] or ""
            end
            break
        end
    end
end

--- Set a new base folder
function FolderManager:setBaseDir(new_base_dir)
    if new_base_dir and new_base_dir ~= "" then
        self.base_dir = new_base_dir:gsub("/+$", "")
    end
end

--- Generate tag list items for e-ink UI rendering
function FolderManager:getPresetTagItems()
    local items = {}
    
    -- Root/Base folder tag
    table.insert(items, {
        name = "Base Root",
        subfolder = "",
        is_active = (self.active_subfolder == ""),
        display_text = "📁 [Root]"
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

--- Recursively creates directories for the target path
-- @param lfs_or_mock table Optional LuaFileSystem or mock for testing
-- @return boolean success, string|nil error_msg
function FolderManager:ensureTargetDirectoryExists(lfs_or_mock)
    local target = self:getTargetPath()
    local fs = lfs_or_mock or (pcall(require, "lfs") and require("lfs") or nil)

    if not fs then
        -- Fallback if lfs not present: system mkdir
        os.execute(string.format('mkdir -p "%s"', target))
        return true
    end

    -- Step-by-step parent directory creation
    local accum = ""
    for part in target:gmatch("[^/]+") do
        accum = accum .. "/" .. part
        local attr = fs.attributes and fs.attributes(accum)
        if not attr then
            local ok, err = fs.mkdir(accum)
            if not ok and not (fs.attributes and fs.attributes(accum)) then
                return false, "Failed to create directory: " .. tostring(err)
            end
        end
    end
    return true
end

return FolderManager
