-- tests/test_ui_dialog_layout.lua
-- Issue 08 rendered-contract test: the main dialog and every secondary dialog
-- are constructed headless against a fake KOReader widget layer, and the
-- tactile-restyle contract is asserted on the widgets that were built —
-- explicit borders, active-state weight, keypad rebuild out of ButtonTable,
-- no min_width, URL mirror format/truncation, and no banned glyphs anywhere.

package.path = "lanfetch.koplugin/?.lua;" .. package.path

local W = {}        -- ordered registry of every constructed widget's options
local strings = {}  -- every user-facing string harvested from those options
local shown = {}    -- widgets handed to UIManager:show, in order

local function harvest(opts)
    if type(opts) ~= "table" then return end
    for _, k in ipairs({ "text", "title", "description", "ok_text", "cancel_text" }) do
        if type(opts[k]) == "string" then table.insert(strings, opts[k]) end
    end
    if type(opts.buttons) == "table" then
        for _, row in ipairs(opts.buttons) do
            if type(row) == "table" then
                for _, b in ipairs(row) do
                    if type(b) == "table" and type(b.text) == "string" then
                        table.insert(strings, b.text)
                    end
                end
            end
        end
    end
end

local function reset()
    W, strings, shown = {}, {}, {}
end

local function capture(kind)
    return function(_, opts)
        opts = opts or {}
        opts._kind = kind
        table.insert(W, opts)
        harvest(opts)
        return opts
    end
end

-- Fake base with InputContainer's extend/new contract (init runs on new).
local function baseWith(kind)
    local Base = { kind = kind }
    Base.__index = Base
    function Base:extend(o)
        local cls = o or {}
        setmetatable(cls, { __index = self })
        cls.__index = cls
        return cls
    end
    function Base:new(o)
        o = o or {}
        o._kind = kind
        o.key_events = o.key_events or {}
        setmetatable(o, self)
        table.insert(W, o)
        harvest(o)
        if o.init then o:init() end
        return o
    end
    return Base
end

package.preload["ui/widget/container/inputcontainer"] = function()
    return baseWith("InputContainer")
end
package.preload["ui/widget/button"] = function()
    local Button = baseWith("Button")
    return Button
end
for _, path in ipairs({
    "ui/widget/verticalgroup", "ui/widget/horizontalgroup",
    "ui/widget/container/framecontainer", "ui/widget/container/centercontainer",
    "ui/widget/container/movablecontainer", "ui/widget/buttontable",
    "ui/widget/verticalspan", "ui/widget/progresswidget",
}) do
    package.preload[path] = function() return { new = capture(path:match("[^/]+$")) } end
end
package.preload["ui/widget/textwidget"] = function()
    local ctor = capture("TextWidget")
    return { new = function(_, opts)
        local w = ctor(nil, opts)
        w.setText = function() end -- progress dialog updates stats in place
        return w
    end }
end
for _, path in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/notification",
    "ui/widget/infomessage",
}) do
    package.preload[path] = function() return { new = capture(path:match("[^/]+$")) } end
end
package.preload["ui/widget/inputdialog"] = function()
    local ctor = capture("InputDialog")
    return { new = function(_, opts)
        local w = ctor(nil, opts)
        function w:getInputText() return self and self.options and self.options.input end
        return w
    end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) table.insert(shown, w) end,
        close = function() end,
        setDirty = function() end,
        nextTick = function(fn) fn() end,
    }
end
package.preload["device"] = function()
    local Screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        getSize = function() return { w = 600, h = 800 } end,
        scaleBySize = function(n) return n end,
    }
    return {
        screen = Screen,
        input = { group = { Back = "Back" } },
        hasKeys = function() return true end,
    }
end
package.preload["ui/size"] = function()
    return {
        radius = { window = 8 },
        border = { window = 2, button = 1 },
        padding = { default = 10, buttontable = 8, button = 8, large = 20 },
        margin = { default = 10 },
    }
end
package.preload["ui/font"] = function()
    local faces = {}
    return { getFace = function(_, name, size)
        local key = name .. "/" .. size
        if not faces[key] then faces[key] = { face_name = name, size = size } end
        return faces[key]
    end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = { _white = true }, COLOR_BLACK = { _black = true } }
end
package.preload["socket"] = function()
    return {
        gettime = function() return 1000.0 end,
        udp = function()
            return {
                setpeername = function() return 1 end,
                getsockname = function() return "192.168.3.5" end,
                close = function() end,
            }
        end,
    }
end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, error = noop }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end }
end
-- The probe is a peer module with its own tests; here it is stubbed so this
-- file exercises the dialog, not socket discovery.
package.preload["subnet_probe"] = function()
    return {
        detectActiveIP = function() return "192.168.3.5" end,
        detectAllActiveIPs = function() return { "192.168.3.5", "192.168.3.6" } end,
        computePrefill = function(ip)
            local o1, o2, o3 = ip:match("^(%d+)%.(%d+)%.(%d+)")
            return { o1, o2, o3, "" }, 4
        end,
    }
end

local LanFetchDialog = require("ui_dialog")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s",
            msg or "", tostring(expected), tostring(actual)))
    end
end
local function assert_true(v, msg)
    if not v then error("FAILED: " .. (msg or "expected truthy")) end
end

local function all_buttons()
    local out = {}
    for _, w in ipairs(W) do
        if w._kind == "Button" then table.insert(out, w) end
    end
    return out
end
local function find_button(text)
    for _, w in ipairs(all_buttons()) do
        if w.text == text then return w end
    end
    return nil
end
local function count_kind(kind)
    local n = 0
    for _, w in ipairs(W) do if w._kind == kind then n = n + 1 end end
    return n
end
local function nchars(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end
local BANNED = { "⚡", "⚠", "⬇", "✏", "\xEF\xB8\x8F" }
local function hasBannedGlyph(s)
    for i = 1, #s do
        if s:byte(i) >= 0xF0 then return true end -- any >= U+10000 (emoji blocks)
    end
    for _, bad in ipairs(BANNED) do
        if s:find(bad, 1, true) then return true end
    end
    return false
end

local function makeFolderManager()
    local fm
    fm = {
        base_dir = "/mnt/downloads",
        presets = { "Inbox", "Articles", "Books/Tech", "Papers/AI", "Work/Reports" },
        active_subfolder = "Inbox",
        getTargetPath = function() return fm.base_dir .. "/" .. fm.active_subfolder end,
        getPresetTagItems = function()
            local items = { {
                name = "Base Root", subfolder = "",
                is_active = (fm.active_subfolder == ""),
                display_text = "[Root]",
            } }
            for _, p in ipairs(fm.presets) do
                table.insert(items, {
                    name = p, subfolder = p,
                    is_active = (fm.active_subfolder == p),
                    display_text = p,
                })
            end
            return items
        end,
        selectPreset = function(_, s) fm.active_subfolder = s end,
        addPreset = function(_, p) table.insert(fm.presets, p) end,
        ensureTargetDirectoryExists = function() return true end,
    }
    return fm
end

local function newDialog()
    return LanFetchDialog:new{ folder_manager = makeFolderManager(), default_port = 9999 }
end

print("== Running UI Dialog Layout (issue 08) Contract Tests ==")

-- Test 1: the main layout constructs headless and produces widgets
reset()
local dlg = newDialog()
assert_true(#W > 20, "buildLayout constructs a populated widget tree")
assert_true(dlg[1] ~= nil, "layout is installed as the dialog content")

-- Test 2: top action strip — every button explicitly thin-bordered, no emoji
assert_true(find_button("Save: Inbox") ~= nil, "Save button present with plain label")
for _, label in ipairs({ "Save: Inbox", "Detect Subnet", "✕ Close" }) do
    local b = find_button(label)
    assert_true(b ~= nil, "top strip button exists: " .. label)
    assert_true((b.bordersize or 0) >= 1, "top strip button bordered: " .. label)
end

-- Test 3: tag ribbon — active pill thick+bold, others thin, + New bordered
local active_pill = find_button("✓ Inbox")
assert_true(active_pill ~= nil, "active preset pill present")
assert_eq(active_pill.bordersize, 3, "active preset pill thick border")
assert_eq(active_pill.text_font_bold, true, "active preset pill bold")
for _, label in ipairs({ "[Root]", "Articles", "+ New", " ◀ ", " ▶ " }) do
    local b = find_button(label)
    assert_true(b ~= nil, "ribbon item present: " .. label)
    assert_true((b.bordersize or 0) >= 1, "ribbon item bordered: " .. label)
end

-- Test 4: segment boxes — fixed widths, no min_width, active thick+bold+bracketed
local n_seg52, n_seg64 = 0, 0
for _, b in ipairs(all_buttons()) do
    assert_eq(b.min_width, nil, "no Button uses the nonexistent min_width field")
    if b.width == 52 then n_seg52 = n_seg52 + 1 end
    if b.width == 64 then n_seg64 = n_seg64 + 1 end
end
assert_eq(n_seg52, 4, "four fixed-width octet boxes")
assert_eq(n_seg64, 1, "one fixed-width port box")
local active_seg = find_button("[]")
assert_true(active_seg ~= nil, "empty focused segment renders as [] without space padding")
assert_eq(active_seg.bordersize, 3, "focused segment thick border")
assert_eq(active_seg.text_font_bold, true, "focused segment bold")
local inactive_seg = find_button("192")
assert_true(inactive_seg ~= nil, "prefilled octet renders")
assert_eq(inactive_seg.bordersize, 1, "unfocused segment thin border")

-- Test 5: URL mirror bar — labeled affordance with Edit cue
local url_btn
for _, b in ipairs(all_buttons()) do
    if type(b.text) == "string" and b.text:find("^URL: http://") then url_btn = b end
end
assert_true(url_btn ~= nil, "URL mirror button labeled with URL: prefix")
assert_true(url_btn.text:find("· Edit$") ~= nil, "URL mirror carries · Edit cue")
assert_true((url_btn.bordersize or 0) >= 1, "URL mirror bordered")

-- Test 6: micro-nav — five segmented buttons, all bordered, no wide labels
for _, label in ipairs({ "⇥ Tab", "◀ Left", "Right ▶", "⌫ Del", "✕ Reset" }) do
    local b = find_button(label)
    assert_true(b ~= nil, "nav segment present: " .. label)
    assert_true((b.bordersize or 0) >= 1, "nav segment bordered: " .. label)
end
assert_true(find_button("⇥ Tab Octet") == nil, "long nav label retired")

-- Test 7: keypad rebuilt from Buttons (not ButtonTable), DOWNLOAD inverted
assert_eq(count_kind("buttontable"), 0, "no ButtonTable in the main layout")
local digit_like = 0
for _, b in ipairs(all_buttons()) do
    -- keypad keys: octet-size single glyphs, excluding fixed-width segment boxes
    if b.face and b.face.size == 22 and nchars(b.text) == 1
        and b.width ~= 52 and b.width ~= 64 then
        digit_like = digit_like + 1
    end
end
assert_eq(digit_like, 14, "14 single-glyph keypad keys at octet size (0-9 : . / and backspace)")
local abc = find_button("ABC / URL")
assert_true(abc ~= nil, "mode-escape key present")
assert_true((abc.bordersize or 0) >= 1, "mode-escape key bordered")
local dl
for _, b in ipairs(all_buttons()) do
    if type(b.text) == "string" and b.text:find("DOWNLOAD") then dl = b end
end
assert_true(dl ~= nil, "DOWNLOAD key present")
assert_eq(dl.bordersize, 3, "DOWNLOAD key thick border")
assert_eq(dl.text_font_bold, true, "DOWNLOAD key bold")
assert_eq(dl.lf_inverted, true, "DOWNLOAD key is the inverted subclass")

-- Test 8: long URLs are middle-ellipsis truncated in the mirror bar
reset()
dlg.tabber.segments.path = string.rep("x", 300)
dlg:refreshUI()
local truncated
for _, b in ipairs(all_buttons()) do
    if type(b.text) == "string" and b.text:find("^URL: ") then truncated = b end
end
assert_true(truncated ~= nil, "URL mirror still present after refresh")
assert_true(#truncated.text < 120, "300-char path truncated to a bounded label")
assert_true(truncated.text:find("…", 1, true) ~= nil, "truncation uses an ellipsis")

-- Test 9: no banned glyphs anywhere in the main layout
for _, s in ipairs(strings) do
    assert_eq(hasBannedGlyph(s), false, "main layout string is glyph-clean: " .. s)
end

-- Test 10: every secondary surface is glyph-clean too
reset()
dlg:showAddFolderDialog()
dlg:showChangeBaseFolderDialog()
dlg:showFolderActionMenu()
dlg:switchToAlphanumericMode()
dlg:showProgressDialog("book.pdf")
dlg:onDownloadProgress(1e6, 2e6, 50, 1e5)
local S = require("download_session").STATE
dlg:onDownloadState(S.PROBING, nil)
dlg:onDownloadState(S.CONFIRMING, { target_dir = "/d", suggested_name = "a.pdf", size = 1234 })
dlg:onDownloadState(S.DOWNLOADING, { filename = "a.pdf" })
dlg:onDownloadState(S.EXTRACTING, { filename = "a.zip" })
dlg:onDownloadState(S.CANCELING, nil)
dlg:onDownloadState(S.COMPLETED, { path = "/d/a.zip", meta = { size = 5e6, filename = "a.zip" } })
dlg:onDownloadState(S.COMPLETED, {
    path = "/d/b.pdf", meta = { size = 5e6, filename = "b.pdf", extracted = { ok = true, files = 3, dir = "/d/b" } },
})
dlg:onDownloadState(S.FAILED, { error = "boom" })
dlg:onDownloadState(S.ABORTED, nil)
dlg:onDownloadState(S.CLOSED, nil)
dlg:detectSubnet(true)
dlg:detectSubnet(true)
for _, s in ipairs(strings) do
    assert_eq(hasBannedGlyph(s), false, "secondary surface string is glyph-clean: " .. s)
end
assert_true(#strings > 30, "the secondary-surface sweep actually exercised strings")

print("All UI dialog layout contract tests passed.")
