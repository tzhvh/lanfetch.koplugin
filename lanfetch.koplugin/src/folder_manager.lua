--[[--
FolderManager: Preset management and recursive directory creation for KOReader.
--]]--

local util = require("util")
local lfs = require("libs/libkoreader-lfs")

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

function FolderManager:getTargetPath()
    if not self.active_subfolder or self.active_subfolder == "" then
        return self.base_dir
    end
    local clean_sub = self.active_subfolder:gsub("^/+", ""):gsub("/+$", "")
    return self.base_dir .. "/" .. clean_sub
end

function FolderManager:selectPreset(subfolder_name)
    self.active_subfolder = subfolder_name or ""
end

function FolderManager:addPreset(new_subfolder)
    if not new_subfolder or new_subfolder == "" then return end
    local clean = new_subfolder:gsub("^/+", ""):gsub("/+$", "")
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

function FolderManager:ensureTargetDirectoryExists()
    local target = self:getTargetPath()
    local success = util.makePath(target)
    return success, target
end

return FolderManager
