--[[--
LanFetchDialog: Fullscreen E-Ink UI with IPv4 Octet Tabber, Tag Switcher, and Custom Keypad.
--]]--

local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/container/verticalgroup")
local HorizontalGroup = require("ui/widget/container/horizontalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local ProgressWidget = require("ui/widget/progresswidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Device = require("device")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local OctetTabber = require("src/octet_tabber")
local SubnetProbe = require("src/subnet_probe")
local URLHandoff = require("src/url_handoff")
local DownloadEngine = require("src/download_engine")

local LanFetchDialog = InputContainer:extend{
    name = "lanfetch_dialog",
    covers_fullscreen = true,
}

function LanFetchDialog:init()
    self.dimen = Screen:getSize()
    self.tabber = OctetTabber.new(nil, self.default_port or 9999, "")
    self.abort_requested = false

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Initial subnet autodetection on launch
    self:detectSubnet(false)

    self[1] = self:buildLayout()
end

function LanFetchDialog:detectSubnet(notify_on_fail)
    local ip = SubnetProbe.detectActiveIP()
    if ip then
        local prefill, focus = SubnetProbe.computePrefill(ip)
        self.tabber:setSubnetPrefill(prefill, focus)
    else
        if notify_on_fail then
            UIManager:show(Notification:new{
                text = _("Could not detect local subnet. Please enter IP manually."),
                timeout = 3,
            })
        end
    end
end

function LanFetchDialog:buildLayout()
    local title_face = Font:getFace("cfont", 22)
    local label_face = Font:getFace("cfont", 18)
    local octet_face = Font:getFace("cfont", 22)
    local btn_face = Font:getFace("cfont", 18)

    local screen_w = Screen:getWidth()
    local margin_w = math.floor(screen_w * 0.04)
    local content_w = screen_w - (margin_w * 2)

    -- 1. TOP HEADER & TAG BAR
    local tag_buttons = {}
    local tag_items = self.folder_manager:getPresetTagItems()
    for _, item in ipairs(tag_items) do
        table.insert(tag_buttons, Button:new{
            text = item.display_text,
            face = btn_face,
            bordersize = item.is_active and 3 or 1,
            margin = 2,
            padding = 6,
            callback = function()
                self.folder_manager:selectPreset(item.subfolder)
                self:refreshUI()
            end,
        })
    end
    table.insert(tag_buttons, Button:new{
        text = _("+ New"),
        face = btn_face,
        margin = 2,
        padding = 6,
        callback = function() self:showAddFolderDialog() end,
    })

    local tag_row = HorizontalGroup:new{
        align = "center",
        table.unpack(tag_buttons)
    }

    local top_action_bar = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = T(_("📁 Save: %1"), self.folder_manager:getTargetPath()),
            face = label_face,
            padding = 6,
            callback = function() self:showFolderActionMenu() end,
        },
        Button:new{
            text = _("⚡ Detect Subnet"),
            face = btn_face,
            padding = 6,
            callback = function()
                self:detectSubnet(true)
                self:refreshUI()
            end,
        },
        Button:new{
            text = _("✕ Close"),
            face = btn_face,
            padding = 6,
            callback = function() self:onClose() end,
        },
    }

    -- 2. URL COMPOSER SEGMENT ROW
    local function makeSegmentBox(key, label_str)
        local is_active = (self.tabber:getActiveKey() == key)
        local is_selected = is_active and self.tabber.is_selected
        local val = self.tabber.segments[key]
        local display = (val ~= "") and val or "   "

        return Button:new{
            text = display,
            face = octet_face,
            bold = is_active,
            bordersize = is_active and 3 or 1,
            padding = 8,
            margin = 2,
            callback = function()
                self.tabber:selectSegment(key)
                self:refreshUI()
            end,
        }
    end

    local octet_row = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = "http://", face = octet_face },
        makeSegmentBox("o1"),
        TextWidget:new{ text = ".", face = octet_face, bold = true },
        makeSegmentBox("o2"),
        TextWidget:new{ text = ".", face = octet_face, bold = true },
        makeSegmentBox("o3"),
        TextWidget:new{ text = ".", face = octet_face, bold = true },
        makeSegmentBox("o4"),
        TextWidget:new{ text = ":", face = octet_face, bold = true },
        makeSegmentBox("port"),
        TextWidget:new{ text = "/", face = octet_face, bold = true },
        makeSegmentBox("path"),
    }

    -- 3. NAVIGATION BAR
    local nav_bar = HorizontalGroup:new{
        align = "center",
        Button:new{ text = _("⇥ Tab Octet"), face = btn_face, padding = 8, margin = 4, callback = function() self.tabber:tab(); self:refreshUI() end },
        Button:new{ text = _("◀ Left"), face = btn_face, padding = 8, margin = 4, callback = function() self.tabber:arrowLeft(); self:refreshUI() end },
        Button:new{ text = _("Right ▶"), face = btn_face, padding = 8, margin = 4, callback = function() self.tabber:arrowRight(); self:refreshUI() end },
        Button:new{ text = _("⌫ Del Box"), face = btn_face, padding = 8, margin = 4, callback = function() self.tabber:backspace(); self:refreshUI() end },
        Button:new{ text = _("✕ Reset"), face = btn_face, padding = 8, margin = 4, callback = function() self.tabber:clear(); self:refreshUI() end },
    }

    -- 4. CUSTOM E-INK 4x4 KEYPAD
    local keypad = ButtonTable:new{
        width = content_w,
        buttons = {
            {
                { text = "1", face = octet_face, callback = function() self.tabber:inputDigit("1"); self:refreshUI() end },
                { text = "2", face = octet_face, callback = function() self.tabber:inputDigit("2"); self:refreshUI() end },
                { text = "3", face = octet_face, callback = function() self.tabber:inputDigit("3"); self:refreshUI() end },
                { text = ":", face = octet_face, callback = function() self.tabber:inputChar(":"); self:refreshUI() end },
            },
            {
                { text = "4", face = octet_face, callback = function() self.tabber:inputDigit("4"); self:refreshUI() end },
                { text = "5", face = octet_face, callback = function() self.tabber:inputDigit("5"); self:refreshUI() end },
                { text = "6", face = octet_face, callback = function() self.tabber:inputDigit("6"); self:refreshUI() end },
                { text = ".", face = octet_face, callback = function() self.tabber:inputChar("."); self:refreshUI() end },
            },
            {
                { text = "7", face = octet_face, callback = function() self.tabber:inputDigit("7"); self:refreshUI() end },
                { text = "8", face = octet_face, callback = function() self.tabber:inputDigit("8"); self:refreshUI() end },
                { text = "9", face = octet_face, callback = function() self.tabber:inputDigit("9"); self:refreshUI() end },
                { text = "/", face = octet_face, callback = function() self.tabber:inputChar("/"); self:refreshUI() end },
            },
            {
                { text = _("ABC / URL"), face = btn_face, callback = function() self:switchToAlphanumericMode() end },
                { text = "0", face = octet_face, callback = function() self.tabber:inputDigit("0"); self:refreshUI() end },
                { text = "⌫", face = octet_face, callback = function() self.tabber:backspace(); self:refreshUI() end },
                { text = _("⬇ DOWNLOAD"), face = btn_face, bold = true, callback = function() self:promptAndDownload() end },
            },
        }
    }

    local main_group = VerticalGroup:new{
        align = "center",
        FrameContainer:new{ margin = 4, padding = 4, bordersize = 0, top_action_bar },
        FrameContainer:new{ margin = 4, padding = 4, bordersize = 1, tag_row },
        FrameContainer:new{ margin = 8, padding = 12, bordersize = 2, octet_row },
        FrameContainer:new{ margin = 4, padding = 4, bordersize = 0, nav_bar },
        FrameContainer:new{ margin = 8, padding = 4, bordersize = 0, keypad },
    }

    return CenterContainer:new{
        dimen = self.dimen,
        main_group
    }
end

function LanFetchDialog:refreshUI()
    self[1] = self:buildLayout()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function LanFetchDialog:showAddFolderDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Add Subfolder Preset"),
        input = "",
        description = _("Enter subfolder name (e.g. Papers/AI):"),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Add"), callback = function()
                    local val = dialog:getInputText()
                    if val and val:match("%S") then
                        self.folder_manager:addPreset(val)
                        if self.on_save_presets then
                            self.on_save_presets(self.folder_manager.presets)
                        end
                        self:refreshUI()
                    end
                    UIManager:close(dialog)
                end },
            }
        }
    }
    UIManager:show(dialog)
end

function LanFetchDialog:showFolderActionMenu()
    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Current Target Folder:\n%1\n\nChoose an action:"), self.folder_manager:getTargetPath()),
        ok_text = _("Open in Files"),
        cancel_text = _("Close"),
        ok_callback = function()
            if self.plugin and self.plugin.openTargetFolder then
                self.plugin:openTargetFolder(self.folder_manager:getTargetPath())
            end
        end,
    }
    UIManager:show(dialog)
end

function LanFetchDialog:switchToAlphanumericMode()
    local current_url = self.tabber:getURL()
    local dialog
    dialog = InputDialog:new{
        title = _("Alphanumeric URL Entry"),
        input = current_url,
        description = _("Enter any URL, domain name, or IPv6 address:"),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("⇄ LAN Mode"), callback = function()
                    local raw = dialog:getInputText()
                    local ok, octs, port, path = URLHandoff.parseURL(raw)
                    if ok then
                        self.tabber.segments.o1 = tostring(octs[1])
                        self.tabber.segments.o2 = tostring(octs[2])
                        self.tabber.segments.o3 = tostring(octs[3])
                        self.tabber.segments.o4 = tostring(octs[4])
                        self.tabber.segments.port = port
                        self.tabber.segments.path = path
                        self.tabber.active_index = 4
                        self.tabber.is_selected = true
                        UIManager:close(dialog)
                        self:refreshUI()
                    else
                        UIManager:show(Notification:new{
                            text = _("URL is not an IPv4 address. Staying in Alphanumeric mode."),
                            timeout = 3,
                        })
                    end
                end },
                { text = _("⬇ Download"), callback = function()
                    local raw = dialog:getInputText()
                    UIManager:close(dialog)
                    self:startDownloadURL(raw)
                end },
            }
        }
    }
    UIManager:show(dialog)
end

function LanFetchDialog:promptAndDownload()
    local target_url = self.tabber:getURL()
    self:startDownloadURL(target_url)
end

function LanFetchDialog:startDownloadURL(target_url)
    local target_dir = self.folder_manager:getTargetPath()
    self.folder_manager:ensureTargetDirectoryExists()

    -- Extract candidate filename
    local candidate_name = DownloadEngine.extractFilenameFromUrl(target_url) or "download.pdf"
    candidate_name = DownloadEngine.sanitizeFilename(candidate_name)

    local confirm_dialog
    confirm_dialog = InputDialog:new{
        title = _("Confirm Download"),
        input = candidate_name,
        description = T(_("Saving to:\n%1"), target_dir),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(confirm_dialog) end },
                { text = _("Download"), callback = function()
                    local custom_name = confirm_dialog:getInputText()
                    custom_name = DownloadEngine.sanitizeFilename(custom_name)
                    UIManager:close(confirm_dialog)
                    self:executeDownload(target_url, target_dir, custom_name)
                end },
            }
        }
    }
    UIManager:show(confirm_dialog)
end

function LanFetchDialog:executeDownload(url, target_dir, custom_filename)
    self.abort_requested = false

    local progress_dialog = ProgressWidget:new{
        text = _("Connecting to LAN server..."),
    }
    UIManager:show(progress_dialog)

    local start_time = UIManager:getElapsedTimeSinceBoot()

    local progress_cb = function(received, total)
        if self.abort_requested then return false end
        local elapsed = math.max(0.1, UIManager:getElapsedTimeSinceBoot() - start_time)
        local speed_kbs = (received / 1024) / elapsed

        local text
        if total and total > 0 then
            local pct = math.floor((received / total) * 100)
            text = string.format("%s (%.1f MB / %.1f MB) - %d%%\nSpeed: %.1f KB/s",
                custom_filename, received / (1024 * 1024), total / (1024 * 1024), pct, speed_kbs)
            progress_dialog:update(received, total, text)
        else
            text = string.format("%s (%.1f MB)\nSpeed: %.1f KB/s",
                custom_filename, received / (1024 * 1024), speed_kbs)
            progress_dialog:update(received, 0, text)
        end
        return true
    end

    local abort_cb = function()
        return self.abort_requested
    end

    -- Run download asynchronously via Trapper
    UIManager:nextTick(function()
        local success, result_or_err, meta = DownloadEngine.download(
            url,
            target_dir,
            { custom_filename = custom_filename, overwrite = false },
            progress_cb,
            abort_cb
        )

        UIManager:close(progress_dialog)

        if success then
            if self.plugin and self.plugin.refreshFileManager then
                self.plugin:refreshFileManager(target_dir)
            end

            UIManager:show(ConfirmBox:new{
                text = T(_("Download Complete!\n\nSaved: %1\nSize: %2 MB"),
                    result_or_err, string.format("%.2f", (meta.size or 0) / (1024 * 1024))),
                ok_text = _("📖 Open PDF"),
                cancel_text = _("Stay Here"),
                ok_callback = function()
                    self:onClose()
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(result_or_err)
                end,
            })
        else
            if tostring(result_or_err) ~= "aborted" then
                UIManager:show(ConfirmBox:new{
                    text = T(_("Download Error:\n%1"), tostring(result_or_err)),
                    ok_text = _("Retry"),
                    cancel_text = _("Close"),
                    ok_callback = function()
                        self:executeDownload(url, target_dir, custom_filename)
                    end,
                })
            end
        end
    end)
end

function LanFetchDialog:onClose()
    UIManager:close(self)
end

return LanFetchDialog
