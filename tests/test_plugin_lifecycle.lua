-- tests/test_plugin_lifecycle.lua
-- Verifies the deferred-I/O plugin lifecycle: plugin init registers menus and
-- dispatcher actions only — no settings I/O, no directory creation, no
-- onboarding dialogs — until the user first invokes the plugin.
--
-- KOReader modules are replaced with counting fakes via package.preload; the
-- plugin's own modules (main.lua, folder_manager.lua) run for real.

package.path = "lanfetch.koplugin/?.lua;" .. package.path

local calls = {}
local function bump(name) calls[name] = (calls[name] or 0) + 1 end

local created_widgets = {}   -- widgets handed to UIManager:show
local shown_widgets = {}     -- same, in show order

-- Fake persisted settings store, shared across plugin instances to simulate
-- state surviving a KOReader restart.
local settings_store = {}

local function fakeWidget(kind)
    return function(_, opts)
        local w = { kind = kind, options = opts or {} }
        if kind == "InputDialog" then
            function w:getInputText() return self and self.options.input end
        end
        table.insert(created_widgets, w)
        return w
    end
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local Base = {}
    Base.__index = Base
    function Base:extend(o)
        local cls = o or {}
        setmetatable(cls, { __index = self })
        cls.__index = cls
        return cls
    end
    function Base:new(o)
        o = o or {}
        setmetatable(o, self)
        if o.init then o:init() end
        return o
    end
    return Base
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() bump("settings_dir"); return "/tmp/lanfetch-test/settings" end,
        getDataDir = function() return "/tmp/lanfetch-test" end,
    }
end
package.preload["luasettings"] = function()
    local LuaSettings = {}
    function LuaSettings:open(path)
        bump("settings_open")
        local s = { file = path, data = settings_store }
        function s:readSetting(key, default)
            if self.data[key] == nil and default ~= nil then self.data[key] = default end
            return self.data[key]
        end
        function s:isTrue(key) return self.data[key] == true end
        function s:saveSetting(key, value) self.data[key] = value end
        function s:flush() bump("flush") end
        return s
    end
    return LuaSettings
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function() bump("nexttick") end,
        show = function(_, w) bump("ui_show"); table.insert(shown_widgets, w) end,
        close = function() end,
    }
end
package.preload["dispatcher"] = function()
    return { registerAction = function() bump("register_action") end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = fakeWidget("ConfirmBox") }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = fakeWidget("InputDialog") }
end
package.preload["apps/filemanager/filemanager"] = function()
    return { instance = nil, showFiles = function() end, reinit = function() end }
end
package.preload["util"] = function()
    return { makePath = function() bump("makepath"); return true end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return (fmt:gsub("%%1", tostring(a))) end }
end
package.preload["ui_dialog"] = function()
    return { new = function(_, opts) bump("dialog_new"); return opts end }
end

local LanFetch = require("main")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end
local function last_of(kind)
    for i = #created_widgets, 1, -1 do
        if created_widgets[i].kind == kind then return created_widgets[i] end
    end
    return nil
end

local function fresh_ui()
    return { menu = { registerToMainMenu = function() bump("register_menu") end } }
end

print("== Running Plugin Lifecycle (deferred I/O) Tests ==")

-- Test 1: init performs no I/O and schedules nothing
local plugin = LanFetch:new{ ui = fresh_ui() }
assert_eq(calls.settings_dir, nil, "init must not resolve settings dir")
assert_eq(calls.settings_open, nil, "init must not open settings file")
assert_eq(calls.makepath, nil, "init must not create directories")
assert_eq(calls.nexttick, nil, "init must not schedule startup callbacks")
assert_eq(calls.dialog_new, nil, "init must not build the downloader dialog")
assert_eq(calls.register_action, 1, "init registers the dispatcher action")
assert_eq(calls.register_menu, 1, "init registers the main menu")

-- Test 2: settings flush before first invocation is inert
plugin:onFlushSettings()
assert_eq(calls.flush, nil, "onFlushSettings must be a no-op before state exists")
assert_eq(calls.settings_open, nil, "onFlushSettings must not force settings open")

-- Test 3: opening our menu entry point opens settings lazily, still no mkdir
local items = plugin:getMenuItems()
assert_eq(calls.settings_open, 1, "getMenuItems opens settings on first use")
assert_eq(calls.makepath, nil, "menu access must not create directories")
assert_eq(#items > 0, true, "menu items are produced")

-- Test 4: first showDownloader triggers onboarding, not the downloader
plugin:showDownloader()
assert_eq(calls.dialog_new, nil, "downloader dialog must wait for onboarding")
local welcome = last_of("ConfirmBox")
assert_eq(welcome ~= nil, true, "onboarding welcome dialog is shown")
assert_eq(calls.settings_open, 1, "state is not re-opened on second entry point")

-- Test 5: skipping onboarding persists the flag; next open shows the dialog
welcome.options.cancel_callback()
assert_eq(settings_store.has_completed_onboarding, true, "skip marks onboarding done")
plugin:showDownloader()
assert_eq(calls.dialog_new, 1, "dialog shown after onboarding completed")
assert_eq(plugin.folder_manager ~= nil, true, "folder manager built before dialog")

-- Test 6: saveFields → flush writes exactly once per change
plugin:saveFields({ default_port = "1234" })
plugin:onFlushSettings()
assert_eq(calls.flush, 1, "flush writes after a saved field")
plugin:onFlushSettings()
assert_eq(calls.flush, 1, "second flush without changes is a no-op")

-- Test 7: full onboarding path (folder step creates the directory on confirm)
created_widgets = {}
settings_store = {}
local plugin2 = LanFetch:new{ ui = fresh_ui() }
plugin2:showDownloader()
last_of("ConfirmBox").options.ok_callback()          -- welcome → folder step
local folder_input = last_of("InputDialog")
folder_input.options.input = "/mnt/test/Downloads"
assert_eq(calls.makepath, nil, "directory created only after user confirms")
folder_input.options.buttons[1][2].callback()         -- Next
assert_eq(calls.makepath >= 1, true, "folder step creates the base directory")
assert_eq(settings_store.base_dir, "/mnt/test/Downloads", "chosen folder persisted")
local tips = last_of("ConfirmBox")
tips.options.ok_callback()                            -- Launch Downloader
assert_eq(settings_store.has_completed_onboarding, true, "onboarding completes")
assert_eq(calls.dialog_new >= 2, true, "launcher opens the downloader dialog")

-- Test 8: a relaunched plugin with persisted state skips onboarding entirely
created_widgets = {}
settings_store = { has_completed_onboarding = true, base_dir = "/mnt/x", presets = { "Inbox" } }
local plugin3 = LanFetch:new{ ui = fresh_ui() }
assert_eq(calls.settings_open, 2, "relaunch opens settings only at init-free state") -- 1 from plugin2
local dialogs_before = calls.dialog_new
plugin3:showDownloader()
assert_eq(calls.dialog_new, dialogs_before + 1, "dialog opens directly")
local confirmboxes = 0
for _, w in ipairs(created_widgets) do
    if w.kind == "ConfirmBox" then confirmboxes = confirmboxes + 1 end
end
assert_eq(confirmboxes, 0, "no onboarding dialogs on a relaunched install")

print("All plugin lifecycle tests passed.")
