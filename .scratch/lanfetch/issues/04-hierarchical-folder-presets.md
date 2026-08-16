Type: prototype
Status: resolved

# Hierarchical Folder Presets & Tag Switcher

## Question

How should the target folder selector represent persistent base folders and hierarchical subfolder presets as e-ink tag buttons with dynamic creation of nested directories?

## Answer

Implemented and validated via [src/folder_manager.lua](file:///home/mser/Documents/cla/exp/down2e/src/folder_manager.lua) and [tests/test_folder_manager.lua](file:///home/mser/Documents/cla/exp/down2e/tests/test_folder_manager.lua).

Key architectural mechanics:
1. **Persistent Base + Subfolder Presets**: A persistent base directory (default `/mnt/onboard/documents/Downloads` or user-configured) stored in `LuaSettings` (`G_reader_settings`), accompanied by a customizable list of hierarchical subfolder presets (`Inbox`, `Articles`, `Work/Reports`, `Books/Tech`).
2. **Top Tag Bar UI**: Rendered as a high-contrast horizontal ribbon of buttons (`Button:new`). The active subfolder tag is rendered with inverted/highlighted styling.
3. **Quick-Switch & Management**: Tapping any tag instantly sets the active target path. Tapping `[ + New ]` prompts with `InputDialog` to add arbitrary deep subfolders (e.g. `Papers/2026/AI`). Long-pressing a tag provides `[ Delete ]` or `[ Set Default ]`.
4. **Recursive Directory Creation**: `ensureTargetDirectoryExists` recursively checks and generates intermediate directory tiers (`lfs.mkdir`) before streaming downloaded PDFs to storage.
