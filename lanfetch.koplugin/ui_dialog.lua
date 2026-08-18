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
local ProgressWidget = require("ui/widget/progresswidget")
local VerticalSpan = require("ui/widget/verticalspan")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Device = require("device")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local socket = require("socket")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local OctetTabber = require("octet_tabber")
local SubnetProbe = require("subnet_probe")
local URLHandoff = require("url_handoff")
local DownloadEngine = require("download_engine")
local DownloadSession = require("download_session")
local SESSION_STATE = DownloadSession.STATE

local LanFetchDialog = InputContainer:extend{
    name = "lanfetch_dialog",
}

function LanFetchDialog:init()
    self.tabber = OctetTabber.new(nil, self.default_port or 9999, "")
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
    local active_tag = (self.folder_manager.active_subfolder and self.folder_manager.active_subfolder ~= "")
        and self.folder_manager.active_subfolder
        or "[Root]"

    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Current Save Path:\n%1\n\nBase: %2\nTag: %3"),
            self.folder_manager:getTargetPath(),
            self.folder_manager.base_dir,
            active_tag),
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
    self:startDownloadURL(self.tabber:getURL())
end

function LanFetchDialog:startDownloadURL(target_url)
    local target_dir = self.folder_manager:getTargetPath()
    self.folder_manager:ensureTargetDirectoryExists()
    self:ensureSession():start(target_url, target_dir)
end

--- The UI side of the DownloadSession seam: dialogs open and close purely in
--- response to session state; the session owns legality, cancellation, retry,
--- and teardown.
function LanFetchDialog:ensureSession()
    if not self.download_session then
        self.download_session = DownloadSession.new{
            engine = DownloadEngine,
            schedule = function(fn) UIManager:nextTick(fn) end,
            on_state = function(state, payload)
                self:onDownloadState(state, payload)
            end,
            on_progress = function(bytes, total, pct, speed)
                self:onDownloadProgress(bytes, total, pct, speed)
            end,
        }
    end
    return self.download_session
end

function LanFetchDialog:onDownloadState(state, payload)
    if state == SESSION_STATE.PROBING then
        self.probe_dialog = InfoMessage:new{
            text = _("Querying server for filename..."),
            dismissable = false,
        }
        UIManager:show(self.probe_dialog)

    elseif state == SESSION_STATE.CONFIRMING then
        if self.probe_dialog then
            UIManager:close(self.probe_dialog)
            self.probe_dialog = nil
        end
        local desc_text = T(_("Saving to:\n%1"), payload.target_dir)
        if payload.size and payload.size > 0 then
            desc_text = desc_text .. string.format("\nFile size: %.1f KB", payload.size / 1024)
        end
        local dialog
        dialog = InputDialog:new{
            title = _("Confirm Download"),
            input = payload.suggested_name,
            description = desc_text,
            buttons = {
                {
                    { text = _("Cancel"), callback = function()
                        UIManager:close(dialog)
                        self.download_session:cancel()
                    end },
                    { text = _("Download"), callback = function()
                        local name = dialog:getInputText()
                        UIManager:close(dialog)
                        self.download_session:confirm(name)
                    end },
                }
            }
        }
        self.confirm_dialog = dialog
        UIManager:show(dialog)

    elseif state == SESSION_STATE.DOWNLOADING then
        if self.probe_dialog then
            UIManager:close(self.probe_dialog)
            self.probe_dialog = nil
        end
        self:showProgressDialog(payload.filename)

    elseif state == SESSION_STATE.CANCELING then
        if self.progress_stats and self.progress_dialog then
            self.progress_stats:setText(_("Canceling download..."))
            UIManager:setDirty(self.progress_dialog, "ui")
        end

    elseif state == SESSION_STATE.COMPLETED then
        self:closeProgressDialog()
        if self.plugin and self.plugin.refreshFileManager then
            self.plugin:refreshFileManager(self.folder_manager:getTargetPath())
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Download Complete!\n\nSaved: %1\nSize: %2 MB"),
                payload.path, string.format("%.2f", (payload.meta and payload.meta.size or 0) / (1024 * 1024))),
            ok_text = _("📖 Open PDF"),
            cancel_text = _("Stay Here"),
            ok_callback = function()
                self:onClose()
                local ReaderUI = require("apps/reader/readerui")
                ReaderUI:showReader(payload.path)
            end,
        })

    elseif state == SESSION_STATE.FAILED then
        self:closeProgressDialog()
        UIManager:show(ConfirmBox:new{
            text = T(_("Download Error:\n%1"), tostring(payload.error)),
            ok_text = _("Retry"),
            cancel_text = _("Close"),
            ok_callback = function()
                self.download_session:retry()
            end,
        })

    elseif state == SESSION_STATE.ABORTED then
        self:closeProgressDialog()
        UIManager:show(Notification:new{
            text = _("Download canceled."),
            timeout = 2,
        })

    elseif state == SESSION_STATE.CLOSED then
        self:closeProgressDialog()
        if self.probe_dialog then
            UIManager:close(self.probe_dialog)
            self.probe_dialog = nil
        end
    end
end

function LanFetchDialog:showProgressDialog(filename)
    local title_face = Font:getFace("cfont", 18)
    local stats_face = Font:getFace("cfont", 14)

    local title_widget = TextWidget:new{
        text = T(_("Downloading: %1"), filename or "document.pdf"),
        face = title_face,
        bold = true,
    }

    local progress_bar = ProgressWidget:new{
        width = Screen:scaleBySize(260),
        height = Screen:scaleBySize(10),
        percentage = 0,
    }

    local stats_widget = TextWidget:new{
        text = _("Connecting to LAN server..."),
        face = stats_face,
    }

    local cancel_button = Button:new{
        text = _("Cancel Download"),
        face = title_face,
        bordersize = 1,
        padding = 6,
        margin = 4,
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            self.download_session:cancel()
        end,
    }

    local progress_group = VerticalGroup:new{
        align = "center",
        title_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        progress_bar,
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        stats_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        cancel_button,
    }

    local progress_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.default,
        margin = Size.margin.default,
        progress_group,
    }

    self.progress_dialog = InputContainer:new{
        CenterContainer:new{
            dimen = Screen:getSize(),
            MovableContainer:new{
                progress_frame
            }
        }
    }
    self.progress_bar = progress_bar
    self.progress_stats = stats_widget
    UIManager:show(self.progress_dialog)
end

function LanFetchDialog:closeProgressDialog()
    if self.progress_dialog then
        UIManager:close(self.progress_dialog)
        self.progress_dialog = nil
        self.progress_bar = nil
        self.progress_stats = nil
    end
end

function LanFetchDialog:onDownloadProgress(received, total, percentage, speed_bps)
    if not self.progress_dialog or not self.progress_stats then return end

    local now = socket.gettime()
    if now - (self._last_progress_ui or 0) < 0.12 and not (total > 0 and received >= total) then
        return
    end
    self._last_progress_ui = now

    local rec_str = (received >= 1024*1024)
        and string.format("%.2f MB", received / (1024 * 1024))
        or string.format("%.1f KB", received / 1024)
    local speed_str = (speed_bps >= 1024*1024)
        and string.format("%.2f MB/s", speed_bps / (1024 * 1024))
        or string.format("%.1f KB/s", speed_bps / 1024)

    if total and total > 0 then
        local tot_str = string.format("%.2f MB", total / (1024 * 1024))
        local pct_int = math.min(100, math.floor(percentage))
        self.progress_stats:setText(string.format("%s / %s (%d%%) • %s", rec_str, tot_str, pct_int, speed_str))
        self.progress_bar.percentage = math.min(1.0, received / total)
    else
        self.progress_stats:setText(string.format("%s • %s", rec_str, speed_str))
    end
    UIManager:setDirty(self.progress_dialog, "ui")
end

function LanFetchDialog:onClose()
    if self.download_session then
        self.download_session:handleClose()
    end
    UIManager:close(self)
end

return LanFetchDialog
