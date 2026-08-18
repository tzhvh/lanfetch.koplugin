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
3. **Pre-Flight Metadata Probing**: A lightweight header-only probe that traverses HTTP redirect chains in $<50\text{ms}$ to discover the true document name and file size before download confirmation — cancellable per operation, with abort checks before every event-loop yield.
4. **Resilient Socket Transport**: A direct streaming socket engine that handles non-standard HTTP 1.0 redirect headers, auto-escapes URL spaces, and writes chunks directly to disk without memory overhead — on a yieldable poll transport that keeps the event loop pumping through connect, TLS, and header reads.
5. **Hierarchical Tag Presets**: A scrollable subfolder ribbon with visual directory browsing (`PathChooser`) and automatic directory creation.
6. **Native Modal Window Architecture**: A centered, movable dialog window conforming to KOReader's native event loop, providing instant dismissal ($<1\text{ms}$) with zero visual ghosting or UI freezes.
7. **Formalized Download Lifecycle**: A session state machine (`DownloadSession`) governing each attempt from start to terminal outcome — illegal transitions are no-ops (double-tap safe), cancellation funnels through a single path that lands within one poll interval even mid-connect, and dialog teardown closes the session without zombie coroutines (ADR-0001).

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
23. As an e-reader user, I want to cancel a download at any time — including while the engine is still connecting or the pre-flight probe is querying — so that a wrong address never blocks my reader for the full network timeout.
24. As an e-reader user, I want a failed download to offer a Retry that reuses my confirmed filename and target without re-probing, so that transient server errors cost one tap to recover from.

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
- Runs on the yieldable hop transport: each connect/TLS/send/read polls the abort flag before yielding, so CANCEL lands mid-operation rather than between hops.
- **Soft-degrade failure semantics**: the probe never throws (guarded by `pcall` in the session) and never fails the attempt — a poor probe result degrades to the confirmation dialog with a fallback name. This is load-bearing: the HTTP→HTTPS protocol fallback exists only in the download path, so an https-only server must not be rejected at probe time.

### 4. Resilient Socket Transport
- Replaces generic HTTP client libraries with a custom raw TCP/TLS socket transport.
- **Redirect Fix**: On receiving any $30\text{x}$ status code, the socket is closed immediately without attempting to read body bytes, ignoring bogus `Content-Length` headers sent on redirects by Android sharing servers (e.g. *ShareViaHttp 2.17*).
- **Whitespace Auto-Encoding**: Raw spaces in redirect `Location` headers (e.g. `Location: PDF Viewer Sandbox.pdf`) are automatically escaped to `%20` before issuing the follow-up request.
- **Protocol Fallback**: Automatically retries with HTTPS (`verify = "none"`) if an HTTP connection fails or receives HTTP 400. Connect-stage failures and HTTP 400 only; SSL errors do not trigger fallback.
- **Direct-to-Disk Streaming**: Streams $8\text{KB}$ chunks directly into `.lanfetch_<timestamp>.tmp` files via `io.open(path, "wb")`, keeping memory consumption constant ($\sim 8\text{KB}$) regardless of file size, finalized by an atomic same-filesystem `os.rename`.
- **Yieldable Poll Transport (as-built)**: every blocking socket operation — connect, TLS handshake, send, line reads, chunk reads — runs as a poll loop at $200\text{ms}$ granularity with the abort checker invoked *before* each yield, under wall-clock caps ($10\text{s}$ connect, $30\text{s}$ read). Refused connections still fail instantly with the real error (an RST needs no polling); only unroutable/filtered targets poll. Same-socket connect retry is used (verified empirically on Linux/LuaSocket: a timed-out connect leaves the socket reusable).
- **One Hop Module (as-built)**: `http_hop.lua` performs a single GET hop (URL parse → connect → TLS → request → status line → headers) shared by both the probe and the download, returning the client positioned at the body, an `aborted` sentinel, or a staged failure descriptor (`connect`/`ssl_handshake`/`malformed_status`/…) that the engine maps to its user-facing error messages. The Host header carries the port unless it is the scheme's default (the pre-unification probe variant omitted it on an edge case).

### 5. Native Modal Window Architecture
- Dialog inherits from `InputContainer` with `modal = true` and `covers_fullscreen = false`.
- Enclosed inside a `FrameContainer` with standard KOReader window tokens (`radius = Size.radius.window`, `bordersize = Size.border.window`, `background = Blitbuffer.COLOR_WHITE`) and centered via `CenterContainer` and `MovableContainer`.
- Dismissal via `UIManager:close(self)` runs in $<1\text{ms}$ without window stack deadlocks.

### 6. Paged Tag Preset Ribbon & Runtime Base Folder Configuration
- Subfolder preset tags are rendered as a horizontal ribbon with a dynamic sliding window (`◀` / `▶` navigation buttons) that activates when tags exceed the physical screen width.
- Creating a tag via `+ New` creates intermediate directories via `util.makePath` and auto-scrolls the ribbon to the new tag.
- Tapping `📁 Save: [Folder]` in the top action bar launches KOReader's native `PathChooser` visual filesystem browser, enabling users to re-target the base folder at any time.

### 7. DownloadSession Lifecycle (as-built, ADR-0001)
- `download_session.lua` is a KOReader-independent state machine at the seam between the dialog and the engine: the engine, the scheduler (one coroutine step), and the `on_state`/`on_progress` observers are injected dependencies.
- States: `IDLE → PROBING → CONFIRMING → DOWNLOADING → COMPLETED | FAILED | ABORTED`, with `CANCELING` entered on cancel from PROBING/DOWNLOADING and unwinding to `ABORTED`; any state may transition to `CLOSED`. `CONFIRMING`-cancel returns directly to `IDLE`.
- **Illegal edges are no-ops** — the transition table *is* the double-tap guard: a second `start()` while active never reaches the engine, and `confirm`/`retry` outside their legal states change nothing.
- **Single cancel path**: `session:cancel()` sets one abort flag the engine polls before every yield; the progress callback no longer doubles as a second abort channel.
- **Retry semantics**: legal only from `FAILED` (download-phase — the probe never fails terminally), reusing the confirmed URL and filename without re-probing.
- **Teardown**: `session:handleClose()` marks the session `CLOSED` synchronously and returns; the engine coroutine keeps unwinding so its terminal funnel closes sockets and removes the partial temp file, but the late outcome is ignored — no dialogs pop over whatever screen is showing, and no coroutine outlives its dialog.
- Orphaned `.lanfetch_*.tmp` files from crashes are swept at the start of each attempt.

### 8. Typed Terminal Outcome Funnel (as-built)
- Every `download()` exit returns one uniform outcome table: `{ kind = KIND.COMPLETED|KIND.ABORTED|KIND.FAILED, path, meta, error }` with `meta` always a table and `error` nil exactly when `kind ~= FAILED` — callers never test for field presence and never string-match sentinel values.
- All exits flow through a single `finish()` funnel owning socket close and temp-file cleanup, so exit hygiene is structural rather than repeated per branch.

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
5. **`tests/test_download_engine.lua`**: Verifies the terminal-funnel contract (uniform outcome shape, no temp-file leakage on failure) plus interleaved mock-server scenarios — byte-identical streaming, CANCEL landing mid-connect, probe redirect-following and cancellation, and fast TLS-handshake failure. The interleaved harness drives the engine in a coroutine and pumps the mock server between engine yields, which is only possible because the transport is yieldable.
6. **`tests/test_download_session.lua`**: Drives the session state machine headless with a fake engine and a manual scheduler — transition guards (double-tap START, illegal confirm/retry), cancel in every phase, retry reusing confirmed args, runtime-error normalization to FAILED, and CLOSED inertness to late engine outcomes.
7. **`tests/test_http_hop.lua`**: Exercises the hop interface directly — body-positioned client on 200, Host-header port rule, aborted sentinel mid-connect, and malformed-status staging.
8. **Live Runtime Integration**: Verified inside the KOReader LuaJIT environment (`koreader-emulator-x86_64-redhat-linux-debug`) against active live HTTP sharing servers (`192.168.3.22:9999`), testing pre-flight probing, 302 redirects, and 94.9 KB PDF transfers.

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
- As-built gap: collision handling currently auto-renames silently (`name (1).pdf`); the interactive collision prompt of story 12 (Overwrite / Auto-Rename / Cancel) awaits a future `COLLIDING` state on the DownloadSession machine — tracked in `issues/05-resilient-download-pipeline.md`.
