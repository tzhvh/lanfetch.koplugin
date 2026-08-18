# LAN PDF Downloader for KOReader

A KOReader plugin that downloads PDFs (and other files) from a local web server on your network directly to your e-reader.  
Useful with apps like *Share via HTTP*, Python’s `http.server`, Calibre’s content server, or any simple LAN file server.

---

## Features

- **E-ink friendly numeric keypad** – large, high-contrast keys; tab between IP octets and port.
- **One-tap subnet detection** – automatically fills the current network prefix (e.g. `192.168.1.`) so you only type the host part.
- **Real filename detection** – reads `Content-Disposition` headers (including UTF-8 / RFC 5987) and follows redirects so the save dialog shows the actual file name and size before downloading.
- **Streaming download** – writes directly to disk, no large RAM usage, and handles quirky embedded servers.
- **Flexible input** – switch to KOReader’s native keyboard for hostnames, full URLs, IPv6, or complex paths.
- **Folder presets** – quick tags for common save locations (`Inbox`, `Articles`, etc.), with automatic folder creation.
- **Native KOReader dialog** – opens and closes instantly, no lag on e-ink screens.
- **Post-download action** – offers **Open PDF** immediately after saving.

---

## Installation

Copy the `lanfetch.koplugin` folder into KOReader’s plugins directory:

| Platform | Plugins directory |
| :--- | :--- |
| Kobo | `/mnt/onboard/.koreader/plugins/` |
| Kindle | `/mnt/us/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| Desktop / Linux | `~/.config/koreader/plugins/` |

Restart KOReader (or reload plugins) after copying.

---

## Usage

### Opening the plugin

- **Top menu** → **Tools** → **More tools** → **LAN PDF Downloader**
- **File manager** → **File manager settings** → **Download PDF from LAN**
- Or assign a gesture / key binding in **Settings → Device → Gestures / Key bindings** to **LAN PDF Downloader: open**

### Downloading a file

1. Tap **⚡ Detect Subnet** (or wait for auto-detection) to fill the local network prefix, e.g. `192.168.3.`.
2. Enter the remaining host octet, e.g. `22`.
3. Tap **⇥ Tab Octet** to move to the **Port** field and enter the port, e.g. `9999`.
4. Tap **⬇ DOWNLOAD**.
5. The plugin checks the server and shows a confirmation with the actual file name and size.
6. Confirm the save location and tap **Download**.
7. When finished, tap **📖 Open PDF** to read it immediately.

### Choosing where to save

- Tap the **📁 Save: …** button to browse and select any folder on the device.
- Tap a preset tag (`Inbox`, `Articles`, etc.) to quickly switch to a subfolder.
- Use **◀** / **▶** to scroll through presets, or **+ New** to create a new subfolder preset.

---

## Notes for developers

The plugin is split into small modules for the keypad, subnet detection, HTTP handling, download engine, and folder presets.  
Unit tests are included under `tests/`.

To run all tests:

```bash
lua tests/test_octet_tabber.lua
lua tests/test_subnet_probe.lua
lua tests/test_url_handoff.lua
lua tests/test_folder_manager.lua
lua tests/test_download_engine.lua
lua tests/test_download_session.lua
lua tests/test_http_hop.lua
```

Syntax check all Lua files:

```bash
luac -p lanfetch.koplugin/*.lua
```

---

## License

AGPLv3, consistent with the KOReader plugin ecosystem.
