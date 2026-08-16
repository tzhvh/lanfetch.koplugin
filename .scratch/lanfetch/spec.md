---
title: "Specification: LAN PDF Downloader for KOReader"
status: "ready-for-agent"
---

## Problem Statement

Reading research papers, manuals, textbooks, and documents on e-ink devices (Kindle, Kobo, Android e-readers) often requires transferring PDF files from a local computer or phone over a local Wi-Fi network (LAN). 

Existing workflows suffer from several friction points:
1. **Awkward Network Entry**: Typing full URLs (`http://192.168.1.145:9999/my_doc.pdf`) using standard QWERTY virtual keyboards on slow e-ink refresh screens is tedious and prone to typos.
2. **Brittle Redirect Handling**: Popular mobile sharing utilities (e.g. *Share via HTTP* on Android) serve files by redirecting the root endpoint (`/`) to the actual file path with unencoded spaces (`Location: PDF Viewer Sandbox.pdf.pdf`) and return non-standard headers (such as a bogus `Content-Length` on 302 responses), causing standard HTTP clients and `curl` to crash with EOF/stream errors.
3. **Loss of Filenames**: When downloading from a bare IP address (`192.168.1.145:9999`), clients cannot determine the real document name before downloading, defaulting to generic names like `download.pdf`.
4. **Disorganized Storage**: Downloaded files are dumped into a single root folder without easy categorization or subfolder tagging.
5. **UI Ghosting and Freezes**: Custom e-ink interfaces that attempt fullscreen replacement often freeze the reader during dismissal or leave dirty visual artifacts on the display.

## Solution

**LAN PDF Downloader (`lanfetch.koplugin`)** is a dedicated, e-ink optimized KOReader plugin that provides:
1. **Structured LAN Mode**: A dedicated 4x4 numeric keypad with a discrete IPv4 octet state machine and single-keystroke segment tabbing.
2. **Zero-Packet Subnet Autodetection**: 1-tap local subnet discovery that prefills the active network address while keeping host octets focused for quick typing.
3. **Pre-Flight Metadata Probing**: A lightweight header-only probe that traverses HTTP redirect chains in $<50\text{ms}$ to discover the true document name and file size before download confirmation.
4. **Resilient Socket Transport**: A direct streaming socket engine that handles non-standard HTTP 1.0 redirect headers, auto-escapes URL spaces, and writes chunks directly to disk without memory overhead.
5. **Hierarchical Tag Presets**: A scrollable subfolder ribbon with visual directory browsing (`PathChooser`) and automatic directory creation.
6. **Native Modal Window Architecture**: A centered, movable dialog window conforming to KOReader's native event loop, providing instant dismissal ($<1\text{ms}$) with zero visual ghosting or UI freezes.

---

## User Stories

1. As an e-reader user, I want the plugin to automatically detect my active LAN subnet on launch, so that I only need to type the last 1–2 host digits of the sender's IP.
2. As an e-reader user, I want a dedicated on-screen numeric keypad with large tap targets, so that I can enter IPv4 addresses and port numbers quickly without switching virtual keyboard layers.
3. As an e-reader user, I want a `⇥ Tab Octet` button that selects the whole next octet for single-digit overwrites, so that I can correct or replace numbers in a single tap.
4. As an e-reader user, I want left and right arrow buttons, so that I can position a cursor inside an octet box without overwriting the entire value.
5. As an e-reader user, I want the full constructed URL to always be visible in real time, so that I have complete confidence in what address will be queried.
6. As an e-reader user, I want to tap the URL bar or the `ABC / URL` button to open the native system QWERTY keyboard, so that I can enter arbitrary domain names, IPv6 addresses, or complex subpaths.
7. As an e-reader user, I want to switch back from the system keyboard to LAN Mode with automatic IPv4 parsing, so that I can resume numeric editing without re-typing.
8. As an e-reader user, I want the plugin to probe server redirects when I enter a bare IP and port, so that the confirmation dialog shows the real document filename instead of `download.pdf`.
9. As an e-reader user, I want the pre-download confirmation dialog to display the expected file size, so that I know how large the document is before saving.
10. As an e-reader user, I want to edit the suggested filename in the confirmation prompt, so that I can organize my library with custom naming conventions.
11. As an e-reader user, I want downloads to stream directly to temporary storage (`.tmp`), so that large PDF books do not consume excessive device RAM or cause out-of-memory crashes.
12. As an e-reader user, I want an automatic collision prompt if a file already exists, so that I can choose between auto-renaming (`file (1).pdf`), overwriting, or cancelling.
13. As an e-reader user, I want a modal progress message showing active download status, so that I know the transfer is progressing.
14. As an e-reader user, I want an immediate prompt with `[ 📖 Open PDF ]` once a download completes, so that I can start reading the document without searching through the file manager.
15. As an e-reader user, I want the File Manager view to refresh automatically in the background, so that newly downloaded files are instantly visible in the library.
16. As an e-reader user, I want a top-level tag ribbon with quick-switch subfolder presets (`Inbox`, `Articles`, `Work/Reports`, `Books/Tech`), so that I can sort incoming documents into categorized folders with one tap.
17. As an e-reader user, I want `◀` and `▶` scrolling arrows on the tag ribbon, so that I can navigate across many subfolder tags without layout clipping on narrow screens.
18. As an e-reader user, I want a `+ New` button on the tag ribbon, so that I can create new nested subfolder tags on demand.
19. As an e-reader user, I want to tap the `📁 Save:` button in the top bar to launch the native visual `PathChooser`, so that I can change my base download directory at any time.
20. As an e-reader user, I want all typed IP addresses and URLs to remain ephemeral in memory, so that sensitive local IP addresses are not permanently written to flash storage.
21. As an e-reader user, I want tapping `✕ Close` or pressing the hardware Back button to dismiss the dialog instantly, so that the device never hangs or freezes.
22. As an e-reader user, I want high-contrast active state indicators (bold borders and checkmarks), so that selected options are crisp and legible on monochrome e-ink screens.

---

## Implementation Decisions

### 1. Dual-Mode Input & Token State Machine
- IPv4 addresses are modeled as five discrete editable tokens (`o1`, `o2`, `o3`, `o4`, `port`) in a specialized state machine.
- Tabbing cycles through numeric segments and flags `is_selected = true`, causing subsequent numeric keystrokes to overwrite the segment contents.
- Arrow keys set `is_selected = false` and navigate character indices non-destructively.
- The URL composer displays the full URL string (`http://192.168.3.22:9999/...`) in real time. Tapping the URL bar or the `ABC / URL` keypad button opens the native `InputDialog` (system QWERTY keyboard) with bidirectional handoff.

```lua
-- Segment State Definition (from prototype)
local SEGMENT_KEYS = { "o1", "o2", "o3", "o4", "port" }
self.segments = { o1 = "192", o2 = "168", o3 = "3", o4 = "22", port = "9999", path = "" }
```

### 2. Zero-Packet Subnet Probe
- Local subnet and IP autodetection uses a non-blocking dummy UDP socket query (`socket.udp():setpeername("1.1.1.1", 80)`).
- Queries the Linux kernel routing table in $<1\text{ms}$ without root privileges, shell executions, or transmitting physical network packets.
- Implements CIDR netmask bitwise math to prefill network octets (/24 $\to$ `192.168.1.`, /16 $\to$ `172.16.`, /8 $\to$ `10.`) while leaving host octets blank for immediate input.

### 3. Pre-Flight Metadata Probe & Filename Derivation
- Prior to showing the confirmation dialog, the engine executes a lightweight header-only probe (`DownloadEngine.probeRemoteMetadata`).
- Follows up to 10 redirect hops ($301, 302, 303, 307, 308$).
- Inspects RFC 5987 / RFC 6266 `Content-Disposition` headers (`filename*=UTF-8''...` and `filename="..."`), redirect `Location` path components, and `Content-Length`.
- Automatically decodes percent-encoded filenames and surfaces the real document name and file size in the confirmation prompt.

### 4. Resilient Socket Transport
- Replaces generic HTTP client libraries with a custom raw TCP/TLS socket transport.
- **Redirect Fix**: On receiving any $30\text{x}$ status code, the socket is closed immediately without attempting to read body bytes, ignoring bogus `Content-Length` headers sent on redirects by Android sharing servers (e.g. *ShareViaHttp 2.17*).
- **Whitespace Auto-Encoding**: Raw spaces in redirect `Location` headers (e.g. `Location: PDF Viewer Sandbox.pdf`) are automatically escaped to `%20` before issuing the follow-up request.
- **Protocol Fallback**: Automatically retries with HTTPS (`verify = "none"`) if an HTTP connection fails or receives HTTP 400.
- **Direct-to-Disk Streaming**: Streams $8\text{KB}$ chunks directly into `.lanfetch_<timestamp>.tmp` files via `io.open(path, "wb")`, keeping memory consumption constant ($\sim 8\text{KB}$) regardless of file size.

### 5. Native Modal Window Architecture
- Dialog inherits from `InputContainer` with `modal = true` and `covers_fullscreen = false`.
- Enclosed inside a `FrameContainer` with standard KOReader window tokens (`radius = Size.radius.window`, `bordersize = Size.border.window`, `background = Blitbuffer.COLOR_WHITE`) and centered via `CenterContainer` and `MovableContainer`.
- Dismissal via `UIManager:close(self)` runs in $<1\text{ms}$ without window stack deadlocks.

### 6. Paged Tag Preset Ribbon & Runtime Base Folder Configuration
- Subfolder preset tags are rendered as a horizontal ribbon with a dynamic sliding window (`◀` / `▶` navigation buttons) that activates when tags exceed the physical screen width.
- Creating a tag via `+ New` creates intermediate directories via `util.makePath` and auto-scrolls the ribbon to the new tag.
- Tapping `📁 Save: [Folder]` in the top action bar launches KOReader's native `PathChooser` visual filesystem browser, enabling users to re-target the base folder at any time.

---

## Testing Decisions

### Good Test Principles
- Tests must verify external contract behavior (URL generation, netmask calculation, URL handoff round-trips, directory creation, filename sanitization, RFC 5987 parsing) rather than internal private variables.
- Network tests must execute against real socket implementations.

### Test Matrix
1. **`tests/test_octet_tabber.lua`**: Verifies 8 discrete state machine operations (tab cycling, digit entry, token selection overwrite, arrow cursor movement, deletion, and full URL assembly).
2. **`tests/test_subnet_probe.lua`**: Verifies CIDR network address calculations for /24, /16, /8 subnets and active kernel IP detection.
3. **`tests/test_url_handoff.lua`**: Verifies bidirectional conversion between IPv4 URLs and structured octet arrays, handling custom ports and paths.
4. **`tests/test_folder_manager.lua`**: Verifies target path concatenation, preset tagging, active tag switching, and `util.makePath` directory creation.
5. **Live Runtime Integration**: Verified inside the KOReader LuaJIT environment (`koreader-emulator-x86_64-redhat-linux-debug`) against active live HTTP sharing servers (`192.168.3.22:9999`), testing pre-flight probing, 302 redirects, and 94.9 KB PDF transfers.

---

## Out of Scope

- Cloud storage provider sync (Dropbox, Google Drive, WebDAV) — handled by existing KOReader cloudstorage plugins.
- Background multi-file download queues or torrent clients.
- Non-PDF document conversion (converting HTML/EPUB on the fly) — handled by KOReader's native render engines.
- Bluetooth or Wi-Fi Direct peer-to-peer discovery protocols.

---

## Further Notes

- Settings are persisted in `settings/lanfetch.lua` (`base_dir`, `presets`, `default_port`, `has_completed_onboarding`).
- All active input data (typed IP, port, path, probe cache) remains strictly ephemeral in memory and is cleared upon dialog exit.
