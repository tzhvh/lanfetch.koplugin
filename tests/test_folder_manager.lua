-- tests/test_folder_manager.lua
package.path = "lanfetch.koplugin/?.lua;" .. package.path
local FolderManager = require("folder_manager")

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

-- Test 8: Path Traversal Prevention
assert_eq(FolderManager.sanitizeSubfolder("../../../../etc"), "etc", "Directory traversal .. must be stripped")
assert_eq(FolderManager.sanitizeSubfolder("../../../etc/passwd"), "etc/passwd", "Traversal in nested path must be sanitized")
assert_eq(FolderManager.sanitizeSubfolder(".."), "", "Lone .. should result in root")
assert_eq(FolderManager.sanitizeSubfolder("."), "", "Lone . should result in root")
assert_eq(FolderManager.sanitizeSubfolder("/absolute/path"), "absolute/path", "Leading absolute slash must be stripped")
assert_eq(FolderManager.sanitizeSubfolder("Books:Tech*?"), "Books_Tech__", "Illegal chars must be replaced with _")

-- Test 9: Path Traversal Attempt in addPreset
fm:addPreset("../../../../etc")
assert_eq(fm.active_subfolder, "etc", "Preset should be sanitized to etc inside base directory")
assert_eq(fm:getTargetPath(), "/mnt/onboard/documents/Downloads/etc", "Target path must remain inside base_dir")

-- Test 10: ensureTargetDirectoryExists Security Check
local ok, path_or_err = fm:ensureTargetDirectoryExists()
assert_eq(ok, true, "Directory creation should succeed inside base_dir")

print("All FolderManager & Tag Preset tests passed successfully!")
