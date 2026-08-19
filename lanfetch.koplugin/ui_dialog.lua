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
local ButtonDialog = require("ui/widget/buttondialog")
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
local ArchiveExtractor = require("archive_extractor")
local SESSION_STATE = DownloadSession.STATE

-- File types KOReader's reader engines can open directly; anything else gets
-- the "open containing folder" action instead of ReaderUI.
local OPENABLE_EXTENSIONS = {
    pdf = true, epub = true, djvu = true, djv = true,
    cbz = true, cbr = true, fb2 = true, mobi = true,
    azw = true, azw3 = true, prc = true, pdb = true, tcr = true,
    txt = true, html = true, xhtml = true, rtf = true, chm = true, doc = true,
    jpg = true, jpeg = true, png = true, gif = true, bmp = true, webp = true, svg = true,
}

-- The keypad's commit key: paint as a normal button, then flip the cell's
-- rectangle so DOWNLOAD reads white-on-black. Stock Button cannot color its
-- text, so the inversion happens at blit time (issue 08).
local InvertedButton = Button:extend{
    lf_inverted = true,
}

function InvertedButton:paintTo(bb, x, y)
    Button.paintTo(self, bb, x, y)
    local d = self.dimen or (self[1] and self[1].dimen)
    if d and d.w and d.h and bb.invertRect then
        bb:invertRect(d.x, d.y, d.w, d.h)
    end
end

-- The URL mirror is a single-line button, so long URLs are middle-ellipsis
-- trimmed to a character budget rather than measured widths (issue 08).
local function fitForURLBar(url, budget)
    if #url <= budget then return url end
    local head_len = math.floor(budget * 0.6)
    local tail_len = budget - head_len - 1
    return url:sub(1, head_len) .. "…" .. url:sub(#url - tail_len + 1)
end

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

    -- Manual tap on "Detect Subnet": Discover all active candidate IPs and cycle
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
            text = T(_("Detected subnet: %1"), ip),
            timeout = 2,
        })
    else
        self.detected_ip_index = ((self.detected_ip_index or 0) % #all_ips) + 1
        local ip = all_ips[self.detected_ip_index]
        local prefill, focus = SubnetProbe.computePrefill(ip)
        self.tabber:setSubnetPrefill(prefill, focus)
        self:refreshUI()
        UIManager:show(Notification:new{
            text = T(_("Subnet (%1/%2): %3 (tap to cycle)"), self.detected_ip_index, #all_ips, ip),
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

    -- 1. TOP ACTION STRIP (issue 08: every button explicitly thin-bordered)
    local top_action_bar = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = T(_("Save: %1"), self.folder_manager:getTargetPath():match("([^/]+)$") or "Downloads"),
            face = label_face,
            bordersize = 1,
            padding = 6,
            margin = 2,
            background = Blitbuffer.COLOR_WHITE,
            callback = function() self:showFolderActionMenu() end,
        },
        Button:new{
            text = _("Detect Subnet"),
            face = label_face,
            bordersize = 1,
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
            bordersize = 1,
            padding = 6,
            margin = 2,
            background = Blitbuffer.COLOR_WHITE,
            callback = function() self:onClose() end,
        },
    }

    -- 2. TAG PRESET RIBBON (Tag Ribbon Paging)
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
        bordersize = 1,
        margin = 2,
        padding = 4,
        background = Blitbuffer.COLOR_WHITE,
        callback = function() self:showAddFolderDialog() end,
    })

    local tag_row = HorizontalGroup:new{
        align = "center",
        table.unpack(tag_buttons)
    }

    -- 3. OCTET SEGMENT BUILDER (issue 08: fixed explicit width — Button has no
    -- min_width field, and the empty-value space padding is gone with it)
    local function makeSegmentBox(key, min_w)
        local is_active = (self.tabber:getActiveKey() == key)
        local is_selected = is_active and self.tabber.is_selected
        local val = self.tabber.segments[key]
        local display = val

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
            width = min_w or 52,
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
    -- Character budget scaled to screen width (~8 px per char at the label
    -- face) rather than pixel measurement, so truncation is deterministic.
    local url_budget = math.floor((content_w - 80) / 8)
    local url_row = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = T(_("URL: %1 · Edit"), fitForURLBar(full_url, url_budget)),
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

    -- 4. MICRO-NAV STRIP (issue 08: five bordered keys — cash-register soft keys;
    -- adjacent borders read as the dividers between segments)
    local nav_bar = HorizontalGroup:new{
        align = "center",
        Button:new{ text = _("⇥ Tab"), face = label_face, bordersize = 1, margin = 0, padding = 6, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:tab(); self:refreshUI() end },
        Button:new{ text = _("◀ Left"), face = label_face, bordersize = 1, margin = 0, padding = 6, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:arrowLeft(); self:refreshUI() end },
        Button:new{ text = _("Right ▶"), face = label_face, bordersize = 1, margin = 0, padding = 6, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:arrowRight(); self:refreshUI() end },
        Button:new{ text = _("⌫ Del"), face = label_face, bordersize = 1, margin = 0, padding = 6, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:backspace(); self:refreshUI() end },
        Button:new{ text = _("✕ Reset"), face = label_face, bordersize = 1, margin = 0, padding = 6, background = Blitbuffer.COLOR_WHITE, callback = function() self.tabber:clear(); self:refreshUI() end },
    }

    -- 5. CUSTOM 4x4 KEYPAD (issue 08: rebuilt from ButtonTable — which
    -- hardcodes zero per-cell borders — into explicit bordered button rows)
    local cell_w = math.floor(content_w / 4) - 4
    local function key(text, face, cb)
        return Button:new{
            text = text, face = face, callback = cb,
            width = cell_w, bordersize = 1, margin = 1, padding = 10,
            background = Blitbuffer.COLOR_WHITE,
        }
    end
    local function digitKey(d)
        return key(d, octet_face, function() self.tabber:inputDigit(d); self:refreshUI() end)
    end
    local function charKey(c)
        return key(c, octet_face, function() self.tabber:inputChar(c); self:refreshUI() end)
    end
    local keypad = VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{ align = "center", digitKey("1"), digitKey("2"), digitKey("3"), charKey(":") },
        HorizontalGroup:new{ align = "center", digitKey("4"), digitKey("5"), digitKey("6"), charKey(".") },
        HorizontalGroup:new{ align = "center", digitKey("7"), digitKey("8"), digitKey("9"), charKey("/") },
        HorizontalGroup:new{
            align = "center",
            key(_("ABC / URL"), btn_face, function() self:switchToAlphanumericMode() end),
            digitKey("0"),
            key("⌫", octet_face, function() self.tabber:backspace(); self:refreshUI() end),
            InvertedButton:new{
                text = _("↓ DOWNLOAD"), face = btn_face,
                text_font_bold = true, bordersize = 3, width = cell_w,
                margin = 1, padding = 10, background = Blitbuffer.COLOR_WHITE,
                callback = function() self:promptAndDownload() end,
            },
        },
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
        ok_text = _("Change Base"),
        cancel_text = _("Open in Files"),
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
                { text = _("↓ Download"), callback = function()
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
    self:ensureSession():start(target_url, target_dir, {
        unzip = self.plugin and self.plugin.auto_unzip and true or false,
    })
end

--- The UI side of the DownloadSession seam: dialogs open and close purely in
--- response to session state; the session owns legality, cancellation, retry,
--- and teardown.
function LanFetchDialog:ensureSession()
    if not self.download_session then
        self.download_session = DownloadSession.new{
            engine = DownloadEngine,
            extractor = ArchiveExtractor,
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

    elseif state == SESSION_STATE.EXTRACTING then
        self:closeProgressDialog()
        if self.complete_dialog then
            UIManager:close(self.complete_dialog)
            self.complete_dialog = nil
        end
        self.extract_dialog = InfoMessage:new{
            text = T(_("Extracting:\n%1"), payload.filename or "archive"),
            dismissable = false,
        }
        UIManager:show(self.extract_dialog)

    elseif state == SESSION_STATE.CANCELING then
        if self.progress_stats and self.progress_dialog then
            self.progress_stats:setText(_("Canceling download..."))
            UIManager:setDirty(self.progress_dialog, "ui")
        end

    elseif state == SESSION_STATE.COMPLETED then
        self:closeProgressDialog()
        if self.extract_dialog then
            UIManager:close(self.extract_dialog)
            self.extract_dialog = nil
        end
        if self.plugin and self.plugin.refreshFileManager then
            self.plugin:refreshFileManager(self.folder_manager:getTargetPath())
        end

        local meta = payload.meta or {}
        local text = T(_("Download Complete!\n\nSaved: %1\nSize: %2 MB"),
            payload.path, string.format("%.2f", (meta.size or 0) / (1024 * 1024)))
        if meta.extracted then
            if meta.extracted.ok then
                text = text .. "\n" .. T(_("Extracted %1 file(s) to:\n%2"),
                    meta.extracted.files or 0, meta.extracted.dir or payload.path)
            else
                text = text .. "\n" .. T(_("Extraction failed: %1\n(archive kept)"),
                    meta.extracted.error or _("unknown error"))
            end
        end

        -- A successful extraction yields a folder; an openable document opens
        -- in the reader; everything else shows its containing folder.
        local open_in_reader = false
        if not (meta.extracted and meta.extracted.ok) then
            local ext = payload.path and payload.path:lower():match("%.([a-z0-9]+)$") or ""
            open_in_reader = ext ~= "" and OPENABLE_EXTENSIONS[ext] == true
        end

        -- A completed, not-yet-extracted .zip offers per-download opt-in
        -- extraction from this dialog (the global auto_unzip setting runs the
        -- same phase before the dialog is ever shown).
        local zip_ready = (not (meta.extracted and meta.extracted.ok))
            and (meta.filename or ""):lower():match("%.zip$") ~= nil

        if zip_ready then
            local dialog
            dialog = ButtonDialog:new{
                title = text,
                title_align = "center",
                buttons = {
                    {{
                        text = _("Unzip"),
                        callback = function()
                            UIManager:close(dialog)
                            self.download_session:extract()
                        end,
                    }},
                    {{
                        text = _("Open Folder"),
                        callback = function()
                            UIManager:close(dialog)
                            self:onClose()
                            if self.plugin and self.plugin.openTargetFolder then
                                local folder = payload.path:match("^(.*)/") or self.folder_manager:getTargetPath()
                                self.plugin:openTargetFolder(folder)
                            end
                        end,
                    }},
                    {{
                        text = _("Stay Here"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    }},
                },
            }
            self.complete_dialog = dialog
            UIManager:show(dialog)
        else
            local dialog
            dialog = ConfirmBox:new{
                text = text,
                ok_text = open_in_reader and _("Open") or _("Open Folder"),
                cancel_text = _("Stay Here"),
                ok_callback = function()
                    self:onClose()
                    if open_in_reader then
                        local ReaderUI = require("apps/reader/readerui")
                        ReaderUI:showReader(payload.path)
                    elseif self.plugin and self.plugin.openTargetFolder then
                        local folder = payload.path
                        if not (meta.extracted and meta.extracted.ok) then
                            folder = payload.path:match("^(.*)/") or self.folder_manager:getTargetPath()
                        end
                        self.plugin:openTargetFolder(folder)
                    end
                end,
            }
            self.complete_dialog = dialog
            UIManager:show(dialog)
        end

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
        if self.extract_dialog then
            UIManager:close(self.extract_dialog)
            self.extract_dialog = nil
        end
        if self.complete_dialog then
            UIManager:close(self.complete_dialog)
            self.complete_dialog = nil
        end
    end
end

function LanFetchDialog:showProgressDialog(filename)
    local title_face = Font:getFace("cfont", 18)
    local stats_face = Font:getFace("cfont", 14)

    local title_widget = TextWidget:new{
        text = T(_("Downloading: %1"), filename or "file"),
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
