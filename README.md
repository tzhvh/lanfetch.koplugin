# LAN PDF Downloader for KOReader (`lanfetch.koplugin`)

A lightweight, resilient, e-ink optimized KOReader plugin to download PDFs served on the local area network (LAN) by bare IP address and port (e.g., from Android apps like *Share via HTTP*, local Python `http.server`, Calibre, or desktop local servers) directly into your reader.

---

## Features

- **E-Ink High-Contrast Keypad**:
  Custom 4x4 numeric keypad with a discrete token state machine (`o1`..`o4`, `port`). Tapping **`⇥ Tab Octet`** highlights the next segment with full-token selection for single-digit overwrites, while arrow keys allow fine cursor navigation.
- **One-Tap Subnet Autodetection**:
  Automatically queries the local Linux/Android kernel routing table in $<1\text{ms}$ (using a zero-packet UDP routing probe) and prefills the active network subnet (`192.168.1.`, `172.16.`, `10.`) leaving host octets blank for rapid entry.
- **Pre-Flight Filename & Redirect Derivation**:
  Derives real filenames and file sizes from server redirect chains ($301, 302, 303, 307, 308$) and RFC 5987 / RFC 6266 `Content-Disposition` UTF-8 headers *before* showing the download confirmation dialog.
- **Resilient Socket Transport**:
  Custom streaming socket client that handles non-standard embedded LAN servers (e.g. *ShareViaHttp 2.17*) with bogus `Content-Length` headers on 302 redirects, auto-encodes raw spaces in redirect URLs, and streams chunks directly to disk without loading large files into RAM.
- **Dual-Mode Coexistence**:
  Seamless bidirectional handoff between the numeric LAN keypad and KOReader's native system virtual keyboard (`InputDialog`) for arbitrary domain names, complex paths, or IPv6.
- **Hierarchical Tag Presets**:
  Quick-switch subfolder presets (`Inbox`, `Articles`, `Work/Reports`, `Books/Tech`, `+ New`) with responsive scrolling arrows (`◀` / `▶`) and native visual directory selection via `PathChooser`.
- **Native Modal Architecture**:
  Engineered as a standard KOReader `modal = true` dialog with `FrameContainer` and `MovableContainer` for instant closing ($<1\text{ms}$) with zero lag or freezing.
- **Post-Download Integration**:
  Automatically triggers file manager refreshes and prompts with **`[ 📖 Open PDF ]`** to open downloaded books immediately.

---

## User Guide

### 1. Installation

Copy the `lanfetch.koplugin` folder to the plugins directory of your KOReader installation:

| Platform | Target Directory |
| :--- | :--- |
| **Kobo** | `/mnt/onboard/.koreader/plugins/lanfetch.koplugin/` |
| **Kindle** | `/mnt/us/koreader/plugins/lanfetch.koplugin/` |
| **Android** | `/sdcard/koreader/plugins/lanfetch.koplugin/` |
| **Linux / Desktop** | `~/.config/koreader/plugins/lanfetch.koplugin/` |
| **Emulator** | `<koreader_source>/plugins/lanfetch.koplugin/` |

Restart KOReader or reload plugins to activate.

---

### 2. How to Use

#### Launching the Downloader
You can access **LAN PDF Downloader** in three ways:
1. **Top Menu**: Tap the **Tools** icon $\to$ **More tools** $\to$ **LAN PDF Downloader**.
2. **File Manager**: Tap the **File Manager Settings** icon $\to$ **Download PDF from LAN**.
3. **Gestures / Keys**: Assign a swipe, corner tap, or hardware key in **Settings** $\to$ **Device** $\to$ **Gestures / Key bindings** to the **LAN PDF Downloader: open** action.

#### Entering an IP & Port
1. Tap **`⚡ Detect Subnet`** in the top bar (or it will auto-detect on launch). The network prefix (e.g. `192.168.3.`) is filled automatically.
2. Type the host octet (e.g. `22`) on the keypad.
3. Tap **`⇥ Tab Octet`** to move to the port and enter `9999` (or leave as default).
4. Tap **`⬇ DOWNLOAD`**.

#### Downloading & Saving
1. The plugin probes the server in $<50\text{ms}$ and derives the real filename (e.g., `PDF Viewer Sandbox.pdf`) and file size.
2. The **Confirm Download** dialog pops up prefilled with the actual filename.
3. Tap **Download** to stream directly to disk.
4. When complete, tap **`📖 Open PDF`** to start reading immediately!

#### Changing Base Download Folder & Presets
- Tap the **`📁 Save: [Folder]`** button in the top action bar to launch the visual **`PathChooser`** browser and select any directory on your device.
- Tap any preset tag in the ribbon (`Inbox`, `Articles`, `Work/Reports`, etc.) to switch target subfolders. Intermediate directories are created automatically.
- Use **`◀`** and **`▶`** to scroll through preset tags if you have many folders, or tap **`+ New`** to create a new subfolder tag.

---

## Developer Guide

### Architecture & Code Layout

```
lanfetch.koplugin/
├── _meta.lua               # Plugin metadata, category, version, and gettext descriptions
├── main.lua                # WidgetContainer entry point, settings persistence, menus, Dispatcher actions
├── ui_dialog.lua           # Native modal window, scrolling tag ribbon, 4x4 keypad, and system keyboard handoff
├── download_engine.lua     # Resilient socket engine, redirect loop, RFC 5987 parser, and streaming sink
├── octet_tabber.lua        # Discrete token state machine for IPv4 octet tabbing and selection overwrite
├── subnet_probe.lua        # Zero-packet UDP dummy socket routing detector & CIDR netmask calculator
├── folder_manager.lua      # Hierarchical preset manager & util.makePath integration
└── url_handoff.lua         # Bidirectional URL parser between LAN mode and alphanumeric mode
```

---

### Running Automated Test Suites

The repository contains automated unit test suites for all algorithmic components (state machine, CIDR math, URL handoff, and folder hierarchy):

```bash
# Run all unit tests
lua tests/test_octet_tabber.lua
lua tests/test_subnet_probe.lua
lua tests/test_url_handoff.lua
lua tests/test_folder_manager.lua
lua tests/test_download_engine.lua
lua tests/test_download_session.lua
lua tests/test_http_hop.lua
```

---

### Syntax Verification

Validate all Lua source files against the LuaJIT syntax compiler:

```bash
luac -p lanfetch.koplugin/*.lua
```

---

### Running in KOReader Desktop Emulator

To test the plugin inside a real KOReader emulator environment:

```bash
# 1. Copy the plugin to your KOReader emulator plugins directory
cp -r lanfetch.koplugin ~/Downloads/koreader/plugins/

# 2. Run KOReader
cd ~/Downloads/koreader
./kodev run
```

---

### Testing Live Download Against Local Server

You can execute a live headless integration test against any running LAN server (e.g. `192.168.3.22:9999`) using the emulator's LuaJIT runtime:

```bash
cd ~/Downloads/koreader/koreader-emulator-x86_64-redhat-linux-debug/koreader
./luajit -e "
dofile('setupkoenv.lua')
local LuaSettings = require('luasettings')
local DataStorage = require('datastorage')
G_reader_settings = LuaSettings:open(DataStorage:getDataDir() .. '/settings.reader.lua')
G_defaults = require('luadefaults'):open()
local Device = require('device')
local CanvasContext = require('document/canvascontext')
CanvasContext:init(Device)

package.path = 'plugins/lanfetch.koplugin/?.lua;' .. package.path
local DownloadEngine = require('download_engine')

local success, path, meta = DownloadEngine.download('http://192.168.3.22:9999', '/tmp')
print('Success:', success, 'Saved to:', path, 'Size:', meta and meta.size)
"
```

---

## License

This project is licensed under the [AGPLv3 License](https://www.gnu.org/licenses/agpl-3.0.html) in accordance with the KOReader plugin ecosystem.
