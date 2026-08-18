--[[--
lanfetch.koplugin: High-speed LAN PDF Downloader for KOReader.
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local FileManager = require("apps/filemanager/filemanager")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local FolderManager = require("folder_manager")
local LanFetchDialog = require("ui_dialog")

local LanFetch = WidgetContainer:extend{
    name = "lanfetch",
    is_doc_only = false,
}

local function getDefaultDownloadPath()
    return DataStorage:getDataDir() .. "/Downloads"
end

function LanFetch:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/lanfetch.lua"
    self.settings = LuaSettings:open(self.settings_file)
    self:loadSettings()
    
    self.folder_manager = FolderManager.new(
        self.base_dir,
        self.presets,
        self.last_subfolder
    )

    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if not self.has_completed_onboarding then
        UIManager:nextTick(function()
            self:showOnboarding()
        end)
    else
        util.makePath(self.base_dir)
    end
end

function LanFetch:loadSettings()
    self.base_dir = self.settings:readSetting("base_dir", getDefaultDownloadPath())
    self.presets = self.settings:readSetting("presets", { "Inbox", "Articles", "Work/Reports", "Books/Tech" })
    self.last_subfolder = self.settings:readSetting("last_subfolder", "Inbox")
    self.default_port = self.settings:readSetting("default_port", "9999")
    self.auto_open = self.settings:readSetting("auto_open", true)
    self.auto_unzip = self.settings:readSetting("auto_unzip", false)
    self.has_completed_onboarding = self.settings:isTrue("has_completed_onboarding")
    self.updated = false
end

function LanFetch:onFlushSettings()
    if self.updated then
        self.settings:flush()
        self.updated = false
    end
end

function LanFetch:saveFields(fields)
    for key, value in pairs(fields) do
        self[key] = value
        self.settings:saveSetting(key, value)
    end
    self.updated = true
end

function LanFetch:onDispatcherRegisterActions()
    Dispatcher:registerAction("lanfetch_open", {
        category = "none",
        event = "LanFetchOpen",
        title = _("LAN PDF Downloader: open"),
        general = true,
    })
end

function LanFetch:onLanFetchOpen()
    self:showDownloader()
end

function LanFetch:addToMainMenu(menu_items)
    menu_items.lanfetch = {
        text = _("LAN PDF Downloader"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:getMenuItems()
        end,
    }

    -- Quick entry in File Manager tab
    if self.ui and self.ui.file_chooser then
        menu_items.lanfetch_quick = {
            text = _("Download from LAN"),
            sorting_hint = "filemanager_settings",
            callback = function() self:showDownloader() end,
        }
    end
end

function LanFetch:getMenuItems()
    local items = {}

    table.insert(items, {
        text = _("Open LAN Downloader"),
        callback = function() self:showDownloader() end,
    })
    table.insert(items, {
        text = _("Open Downloads Folder"),
        callback = function() self:openTargetFolder(self.folder_manager:getTargetPath()) end,
    })
    table.insert(items, { text = "───", separator = true })
    table.insert(items, {
        text = _("Download Settings"),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Base Path: %1"), self.base_dir)
                end,
                callback = function() self:promptBaseFolder() end,
            },
            {
                text_func = function()
                    return T(_("Default Port: %1"), self.default_port)
                end,
                callback = function() self:promptDefaultPort() end,
            },
            {
                text_func = function()
                    return T(_("Unzip Archives: %1"), self.auto_unzip and _("on") or _("off"))
                end,
                callback = function()
                    self:saveFields({ auto_unzip = not self.auto_unzip })
                end,
            },
        },
    })
    table.insert(items, {
        text = _("Setup Wizard / Help"),
        callback = function() self:showOnboarding() end,
    })

    return items
end

function LanFetch:showDownloader()
    local dialog = LanFetchDialog:new{
        plugin = self,
        folder_manager = self.folder_manager,
        default_port = self.default_port,
        on_save_presets = function(new_presets)
            self:saveFields({ presets = new_presets })
        end,
        on_save_base_dir = function(new_base_dir)
            self.base_dir = new_base_dir
            self:saveFields({ base_dir = new_base_dir })
        end,
    }
    UIManager:show(dialog)
end

function LanFetch:promptBaseFolder()
    local dialog
    dialog = InputDialog:new{
        title = _("Configure Base Download Folder"),
        input = self.base_dir,
        description = _("All downloads will be stored inside this directory:"),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Save"), callback = function()
                    local val = dialog:getInputText()
                    if val and val:match("%S") then
                        val = val:gsub("/+$", "")
                        util.makePath(val)
                        self.base_dir = val
                        self.folder_manager:setBaseDir(val)
                        self:saveFields({ base_dir = val })
                    end
                    UIManager:close(dialog)
                end },
            }
        }
    }
    UIManager:show(dialog)
end

function LanFetch:promptDefaultPort()
    local dialog
    dialog = InputDialog:new{
        title = _("Default LAN Port"),
        input = tostring(self.default_port),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Save"), callback = function()
                    local val = dialog:getInputText()
                    if val and tonumber(val) then
                        self.default_port = val
                        self:saveFields({ default_port = val })
                    end
                    UIManager:close(dialog)
                end },
            }
        }
    }
    UIManager:show(dialog)
end

function LanFetch:showOnboarding()
    UIManager:show(ConfirmBox:new{
        text = _([[Welcome to LAN PDF Downloader!

Download files from any local computer or server using a bare IP address and port — PDFs, EPUBs, HTML, Markdown, ZIP archives and more.

Features:
• Auto-detects your local subnet with one tap.
• Quick Octet Tabbing with selection overwrite.
• Instant switching to system keyboard for alphanumeric URLs.
• Hierarchical folder preset tags.]]),
        ok_text = _("Configure Folder"),
        cancel_text = _("Skip"),
        ok_callback = function()
            self:onboardingStepFolder()
        end,
        cancel_callback = function()
            self:saveFields({ has_completed_onboarding = true })
        end,
    })
end

function LanFetch:onboardingStepFolder()
    local dialog
    dialog = InputDialog:new{
        title = _("Step 1 of 2: Download Folder"),
        input = self.base_dir,
        description = _("Choose the base directory where downloaded files will be saved:"),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Next"), callback = function()
                    local val = dialog:getInputText()
                    if val and val:match("%S") then
                        val = val:gsub("/+$", "")
                        util.makePath(val)
                        self.base_dir = val
                        self.folder_manager:setBaseDir(val)
                        self:saveFields({ base_dir = val })
                        UIManager:close(dialog)
                        self:onboardingStepTips()
                    end
                end },
            }
        }
    }
    UIManager:show(dialog)
end

function LanFetch:onboardingStepTips()
    UIManager:show(ConfirmBox:new{
        text = _([[Keypad Shortcuts & Affordances:

• [Tab Octet]: Cycle through IP segments. Typing a number replaces the whole segment!
• [◀ / ▶]: Cancel selection and navigate characters.
• [⌫ Del Box]: Clear the selected segment in one tap.
• [ABC / URL]: Open full virtual keyboard for domain names & filenames.
• [⚡ Detect Subnet]: Auto-fills your active LAN network address.]]),
        ok_text = _("Launch Downloader"),
        cancel_text = _("Close"),
        ok_callback = function()
            self:saveFields({ has_completed_onboarding = true })
            self:showDownloader()
        end,
        cancel_callback = function()
            self:saveFields({ has_completed_onboarding = true })
        end,
    })
end

function LanFetch:openTargetFolder(path)
    util.makePath(path)
    if FileManager.instance then
        FileManager.instance:reinit(path)
    else
        FileManager:showFiles(path)
    end
end

function LanFetch:refreshFileManager(path)
    local FM = FileManager.instance
    if FM and FM.active_tasks == 0 then
        local _, current_path = FM:getCurrentPath()
        if current_path and current_path:gsub("/$", "") == path:gsub("/$", "") then
            FM:refresh()
        end
    end
end

return LanFetch
