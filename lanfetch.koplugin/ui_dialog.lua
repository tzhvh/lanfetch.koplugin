--[[--
LanFetchDialog: Fullscreen E-Ink UI with IPv4 Octet Tabber, Tag Switcher, and Custom Keypad.
--]]--

local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Device = require("device")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local OctetTabber = require("octet_tabber")
local SubnetProbe = require("subnet_probe")
local URLHandoff = require("url_handoff")
local DownloadEngine = require("download_engine")

local LanFetchDialog = InputContainer:extend{
    name = "lanfetch_dialog",
    modal = true,
}

function LanFetchDialog:init()
    self.tabber = OctetTabber.new(nil, self.default_port or 9999, "")
    self.abort_requested = false
    self.tag_scroll_offset = 1

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Initial subnet autodetection on launch
    self:detectSubnet(false)

    self[1] = self:buildLayout()
end

function LanFetchDialog:detectSubnet(manual_tap)
    if not manual_tap then
        -- Fast path on launch: instant single lookup, no notifications
        local ip = SubnetProbe.detectActiveIP()
        if ip then
            local prefill, focus = SubnetProbe.computePrefill(ip)
            self.tabber:setSubnetPrefill(prefill, focus)
        end
        return
    end

    -- Manual tap on "⚡ Detect Subnet": Discover all active candidate IPs and cycle
    local all_ips = SubnetProbe.detectAllActiveIPs()
    if #all_ips == 0 then
        UIManager:show(Notification:new{
            text = _("Could not detect local subnet. Please enter IP manually."),
            timeout = 3,
        })
        return
    end

    if #all_ips == 1 then
        local ip = all_ips[1]
        local prefill, focus = SubnetProbe.computePrefill(ip)
        self.tabber:setSubnetPrefill(prefill, focus)
        self:refreshUI()
        UIManager:show(Notification:new{
            text = T(_("⚡ Detected Subnet: %1"), ip),
            timeout = 2,
        })
    else
        self.detected_ip_index = ((self.detected_ip_index or 0) % #all_ips) + 1
        local ip = all_ips[self.detected_ip_index]
        local prefill, focus = SubnetProbe.computePrefill(ip)
        self.tabber:setSubnetPrefill(prefill, focus)
        self:refreshUI()
        UIManager:show(Notification:new{
            text = T(_("⚡ Subnet (%1/%2): %3 (tap to cycle)"), self.detected_ip_index, #all_ips, ip),
            timeout = 3,
        })
    end
end

function LanFetchDialog:buildLayout()
    local title_face = Font:getFace("cfont", 20)
    local label_face = Font:getFace("cfont", 16)
    local octet_face = Font:getFace("cfont", 22)
    local btn_face = Font:getFace("cfont", 18)

    local screen_w = Screen:getWidth()
    local margin_w = math.floor(screen_w * 0.03)
    local content_w = screen_w - (margin_w * 2)

    -- 1. TOP ACTION BAR
    local top_action_bar = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = T(_("📁 Save: %1"), self.folder_manager:getTargetPath():match("([^/]+)$") or "Downloads"),
            face = label_face,
            padding = 6,
            margin = 2,
            background = Blitbuffer.COLOR_WHITE,
            callback = function() self:showFolderActionMenu() end,
        },
        Button:new{
            text = _("⚡ Detect Subnet"),
            face = label_face,
            padding = 6,
            margin = 2,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                self:detectSubnet(true)
                self:refreshUI()
            end,
        },
        Button:new{
            text = _("✕ Close"),
            face = label_face,
            padding = 6,
            margin = 2,
            background = Blitbuffer.COLOR_WHITE,
            callback = function() self:onClose() end,
        },
    }

    -- 2. SCROLLABLE TAG PRESET RIBBON
    local tag_items = self.folder_manager:getPresetTagItems()
    local total_tags = #tag_items
    local max_visible_tags = math.max(3, math.floor(screen_w / 140))
    local needs_scroll = (total_tags > max_visible_tags)

    if not self.tag_scroll_offset then
        self.tag_scroll_offset = 1
    end
    self.tag_scroll_offset = math.max(1, math.min(self.tag_scroll_offset, total_tags - max_visible_tags + 1))

    local tag_buttons = {}

    -- Left scrolling arrow
    if needs_scroll then
        local can_scroll_left = (self.tag_scroll_offset > 1)
        table.insert(tag_buttons, Button:new{
            text = " ◀ ",
            face = label_face,
            bordersize = 1,
            enabled = can_scroll_left,
            margin = 1,
            padding = 4,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                if self.tag_scroll_offset > 1 then
                    self.tag_scroll_offset = self.tag_scroll_offset - 1
                    self:refreshUI()
                end
            end,
        })
    end

    -- Visible slice of tags
    local start_idx = self.tag_scroll_offset
    local end_idx = needs_scroll and math.min(total_tags, self.tag_scroll_offset + max_visible_tags - 1) or total_tags

    for i = start_idx, end_idx do
        local item = tag_items[i]
        local tag_label = (item.is_active and "✓ " or "") .. item.display_text
        table.insert(tag_buttons, Button:new{
            text = tag_label,
            face = label_face,
            text_font_bold = item.is_active,
            bordersize = item.is_active and 3 or 1,
            margin = 2,
            padding = 4,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                self.folder_manager:selectPreset(item.subfolder)
                self:refreshUI()
            end,
        })
    end

    -- Right scrolling arrow
    if needs_scroll then
        local can_scroll_right = (self.tag_scroll_offset + max_visible_tags - 1 < total_tags)
        table.insert(tag_buttons, Button:new{
            text = " ▶ ",
            face = label_face,
            bordersize = 1,
            enabled = can_scroll_right,
            margin = 1,
            padding = 4,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                if self.tag_scroll_offset + max_visible_tags - 1 < total_tags then
                    self.tag_scroll_offset = self.tag_scroll_offset + 1
                    self:refreshUI()
                end
            end,
        })
    end

    table.insert(tag_buttons, Button:new{
        text = _("+ New"),
        face = label_face,
        margin = 2,
        padding = 4,
        background = Blitbuffer.COLOR_WHITE,
        callback = function() self:showAddFolderDialog() end,
    })

    local tag_row = HorizontalGroup:new{
        align = "center",
        table.unpack(tag_buttons)
    }

    -- 3. SEGMENT BOX BUILDER
    local function makeSegmentBox(key, min_w)
        local is_active = (self.tabber:getActiveKey() == key)
        local is_selected = is_active and self.tabber.is_selected
        local val = self.tabber.segments[key]
        local display = (val ~= "") and val or "   "

        if is_selected then
            display = "[" .. display .. "]"
        end

        return Button:new{
            text = display,
            face = octet_face,
            text_font_bold = is_active,
            bordersize = is_active and 3 or 1,
            padding = 6,
            margin = 2,
            min_width = min_w or 52,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                self.tabber:selectSegment(key)
                self:refreshUI()
            end,
        }
    end

    -- Split URL composer into 2 clean, spacious rows for zero overflow
    local ip_row = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = "http://", face = label_face },
        makeSegmentBox("o1", 52),
        TextWidget:new{ text = ".", face = octet_face, bold = true },
        makeSegmentBox("o2", 52),
        TextWidget:new{ text = ".", face = octet_face, bold = true },
        makeSegmentBox("o3", 52),
        TextWidget:new{ text = ".", face = octet_face, bold = true },
        makeSegmentBox("o4", 52),
        TextWidget:new{ text = " : ", face = octet_face, bold = true },
        makeSegmentBox("port", 64),
    }

    local full_url = self.tabber:getURL()
    local url_row = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = T(_("🔗 %1  ✏️"), full_url),
            face = label_face,
            bordersize = 1,
            padding = 6,
            margin = 2,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                self:switchToAlphanumericMode()
            end,
        }
    }

    -- 4. NAVIGATION BAR
    local nav_bar = HorizontalGroup:new{
        align = "center",
        Button:new{ text = _("⇥ Tab Octet"), face = label_face, padding = 6, margin = 2, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:tab(); self:refreshUI() end },
        Button:new{ text = _("◀ Left"), face = label_face, padding = 6, margin = 2, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:arrowLeft(); self:refreshUI() end },
        Button:new{ text = _("Right ▶"), face = label_face, padding = 6, margin = 2, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:arrowRight(); self:refreshUI() end },
        Button:new{ text = _("⌫ Del Box"), face = label_face, padding = 6, margin = 2, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:backspace(); self:refreshUI() end },
        Button:new{ text = _("✕ Reset"), face = label_face, padding = 6, margin = 2, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:clear(); self:refreshUI() end },
    }

    -- 5. CUSTOM 4x4 KEYPAD
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
        FrameContainer:new{ margin = 2, padding = 4, bordersize = 0, background = Blitbuffer.COLOR_WHITE, top_action_bar },
        FrameContainer:new{ margin = 2, padding = 4, bordersize = 1, background = Blitbuffer.COLOR_WHITE, tag_row },
        FrameContainer:new{
            margin = 4,
            padding = 6,
            bordersize = 2,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "center",
                ip_row,
                FrameContainer:new{ margin = 2, bordersize = 0, background = Blitbuffer.COLOR_WHITE, url_row }
            }
        },
        FrameContainer:new{ margin = 2, padding = 4, bordersize = 0, background = Blitbuffer.COLOR_WHITE, nav_bar },
        FrameContainer:new{ margin = 4, padding = 2, bordersize = 0, background = Blitbuffer.COLOR_WHITE, keypad },
    }

    local window_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.default,
        margin = Size.margin.default,
        main_group,
    }

    return CenterContainer:new{
        dimen = Screen:getSize(),
        MovableContainer:new{
            window_frame
        }
    }
end

function LanFetchDialog:refreshUI()
    if self[1] and self[1].free then
        self[1]:free()
    end
    self[1] = self:buildLayout()
    UIManager:setDirty(self, "ui")
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
                        self.tag_scroll_offset = math.max(1, #self.folder_manager:getPresetTagItems() - 2)
                        self:refreshUI()
                    end
                    UIManager:close(dialog)
                end },
            }
        }
    }
    UIManager:show(dialog)
end

function LanFetchDialog:showChangeBaseFolderDialog()
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
    if ok_pc and PathChooser then
        local chooser
        chooser = PathChooser:new{
            title = _("Select Base Download Folder"),
            select_file = false,
            show_files = false,
            path = self.folder_manager.base_dir,
            onConfirm = function(chosen_path)
                if chosen_path and chosen_path ~= "" then
                    self.folder_manager:setBaseDir(chosen_path)
                    if self.on_save_base_dir then
                        self.on_save_base_dir(chosen_path)
                    end
                    self:refreshUI()
                end
            end
        }
        UIManager:show(chooser)
    else
        local dialog
        dialog = InputDialog:new{
            title = _("Configure Base Folder"),
            input = self.folder_manager.base_dir,
            description = _("Enter base directory path:"),
            buttons = {
                {
                    { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                    { text = _("Save"), callback = function()
                        local val = dialog:getInputText()
                        if val and val:match("%S") then
                            val = val:gsub("/+$", "")
                            self.folder_manager:setBaseDir(val)
                            if self.on_save_base_dir then
                                self.on_save_base_dir(val)
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
end

function LanFetchDialog:showFolderActionMenu()
    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Current Save Path:\n%1\n\nBase: %2\nTag: %3"),
            self.folder_manager:getTargetPath(),
            self.folder_manager.base_dir,
            self.folder_manager.active_preset or "[Root]"),
        ok_text = _("📁 Change Base"),
        cancel_text = _("📂 Open in Files"),
        ok_callback = function()
            self:showChangeBaseFolderDialog()
        end,
        cancel_callback = function()
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

    local initial_candidate = DownloadEngine.extractFilenameFromUrl(target_url)

    -- If no explicit filename in URL path, probe server redirects and headers
    if not initial_candidate or initial_candidate == "" then
        local probe_dialog = InfoMessage:new{
            text = _("Querying server for filename..."),
            dismissable = false,
        }
        UIManager:show(probe_dialog)

        UIManager:nextTick(function()
            local probed_name, final_url, expected_size = DownloadEngine.probeRemoteMetadata(target_url, 4)
            UIManager:close(probe_dialog)

            local candidate_name = probed_name or "download.pdf"
            candidate_name = DownloadEngine.sanitizeFilename(candidate_name)

            local desc_text = T(_("Saving to:\n%1"), target_dir)
            if expected_size and expected_size > 0 then
                desc_text = desc_text .. string.format("\nFile size: %.1f KB", expected_size / 1024)
            end

            local confirm_dialog
            confirm_dialog = InputDialog:new{
                title = _("Confirm Download"),
                input = candidate_name,
                description = desc_text,
                buttons = {
                    {
                        { text = _("Cancel"), callback = function() UIManager:close(confirm_dialog) end },
                        { text = _("Download"), callback = function()
                            local custom_name = confirm_dialog:getInputText()
                            custom_name = DownloadEngine.sanitizeFilename(custom_name)
                            UIManager:close(confirm_dialog)
                            self:executeDownload(final_url or target_url, target_dir, custom_name)
                        end },
                    }
                }
            }
            UIManager:show(confirm_dialog)
        end)
    else
        local candidate_name = DownloadEngine.sanitizeFilename(initial_candidate)
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
end

function LanFetchDialog:executeDownload(url, target_dir, custom_filename)
    self.abort_requested = false

    local progress_dialog = InfoMessage:new{
        text = T(_("Downloading from LAN...\n%1"), custom_filename),
        dismissable = false,
    }
    UIManager:show(progress_dialog)

    local progress_cb = function(received, total)
        if self.abort_requested then return false end
        return true
    end

    local abort_cb = function()
        return self.abort_requested
    end

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
