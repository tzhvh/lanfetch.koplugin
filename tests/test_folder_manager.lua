-- tests/test_folder_manager.lua
local FolderManager = require("src.folder_manager")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

print("== Running FolderManager & Tag Preset Tests ==")

-- Test 1: Initialization & Target Path
local fm = FolderManager.new("/mnt/onboard/documents/Downloads", { "Inbox", "Articles", "Work/Reports" }, "Inbox")
assert_eq(fm:getTargetPath(), "/mnt/onboard/documents/Downloads/Inbox", "Target path should match active preset")

-- Test 2: Switch Preset
fm:selectPreset("Work/Reports")
assert_eq(fm:getTargetPath(), "/mnt/onboard/documents/Downloads/Work/Reports", "Target path should switch to Work/Reports")

-- Test 3: Select Root/Base
fm:selectPreset("")
assert_eq(fm:getTargetPath(), "/mnt/onboard/documents/Downloads", "Target path should be base dir when subfolder is empty")

-- Test 4: Add New Nested Hierarchical Preset
fm:addPreset("Papers/2026/AI")
assert_eq(fm.active_subfolder, "Papers/2026/AI", "New preset should become active")
assert_eq(fm:getTargetPath(), "/mnt/onboard/documents/Downloads/Papers/2026/AI", "Resolved nested path check")

-- Test 5: Avoid Duplicates
local count_before = #fm.presets
fm:addPreset("Papers/2026/AI")
assert_eq(#fm.presets, count_before, "Duplicate preset must not increase count")

-- Test 6: Remove Preset
fm:removePreset("Papers/2026/AI")
assert_eq(fm.active_subfolder, "Inbox", "Removing active preset should fallback to first remaining")

-- Test 7: UI Tag Items Generation
local tags = fm:getPresetTagItems()
assert_eq(#tags, 4, "Should have 1 root tag + 3 presets")
assert_eq(tags[1].display_text, "📁 [Root]", "First item is root")
assert_eq(tags[2].is_active, true, "Inbox should be active")

-- Test 8: Recursive directory creation mock
local created_dirs = {}
local mock_lfs = {
    attributes = function(path)
        return created_dirs[path] and { mode = "directory" } or nil
    end,
    mkdir = function(path)
        created_dirs[path] = true
        return true
    end
}

fm:selectPreset("Science/Physics/Quantum")
local ok, err = fm:ensureTargetDirectoryExists(mock_lfs)
assert_eq(ok, true, "Directory creation should succeed")
assert_eq(created_dirs["/mnt/onboard/documents/Downloads/Science"] ~= nil, true, "Intermediate folder /Science created")
assert_eq(created_dirs["/mnt/onboard/documents/Downloads/Science/Physics"] ~= nil, true, "Intermediate folder /Physics created")
assert_eq(created_dirs["/mnt/onboard/documents/Downloads/Science/Physics/Quantum"] ~= nil, true, "Leaf folder /Quantum created")

print("All FolderManager & Tag Preset tests passed successfully!")
