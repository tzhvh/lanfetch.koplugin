# LAN PDF Downloader

A KOReader plugin for downloading files served over a local area network — PDFs, EPUBs, HTML, Markdown, ZIP archives and more — to an e-ink reader with an IPv4-optimized keypad, portable subnet autodetection, hierarchical folder presets, optional archive unzipping, and ephemeral URL state.

## Language

### Input & Interaction

**LAN Mode**:
The primary structured IPv4 input mode featuring discrete octet boxes, port segment, and a custom on-screen e-ink keypad.
_Avoid_: IP mode, local mode, numeric mode

**Alphanumeric Mode**:
The secondary freeform text input mode delegating to KOReader's native virtual keyboard for arbitrary URLs, domain names, and IPv6.
_Avoid_: QWERTY mode, system mode, full keyboard mode

**Octet Segment**:
An individual 8-bit segment of an IPv4 address modeled as a discrete editable token rather than a substring of a plain text string.
_Avoid_: IP chunk, byte box, octet string

**Octet Tabber**:
The state machine governing focus, whole-segment selection highlighting, overwrite on digit entry, and arrow-based selection cancellation across octet segments.
_Avoid_: Focus switcher, segment cycler, tab manager

### Storage & Organization

**Target Folder**:
The destination path on the e-reader storage where downloaded PDFs are saved, formed by combining a persistent base folder and an active subfolder preset.
_Avoid_: Save path, download destination, target directory

**Subfolder Preset**:
A selectable subfolder tag or recent directory path displayed as a quick-switch button on the main screen.
_Avoid_: Folder tag, category chip, subfolder item

### Networking & Pipeline

**Subnet Probe**:
The non-blocking UDP dummy socket query used to determine the active LAN IP and subnet without transmitting network packets or relying on platform-specific shell tools.
_Avoid_: IP detector, interface scraper, subnet scanner

**Download Pipeline**:
The streaming network transfer engine that negotiates HTTP/HTTPS protocols, follows redirects, extracts filenames from Content-Disposition headers, and writes data directly to storage.
_Avoid_: Fetcher, file downloader, transfer client

**DownloadSession**:
The state machine governing one download attempt from start to terminal outcome (completed, failed, aborted, or closed), owning transition legality, the single cancel path, retry, and teardown at the seam between the dialog and the Download Pipeline.
_Avoid_: Download manager, transfer controller, download controller

**Filename Resolver**:
The multi-tier algorithm that extracts a suggested filename from the URL path, decodes RFC 5987 Content-Disposition headers, or prompts the user with a fallback name.
_Avoid_: Name parser, title extractor

**Filename Sanitizer**:
The filesystem-safety filter that strips prohibited characters, trims leading/trailing dots and whitespace, and caps the filename length at 200 characters. Format-neutral: a name's own extension is authoritative; only extensionless names gain one.
_Avoid_: Name cleaner, path validator

**Content-Type Extension Resolution**:
The rule completing an extensionless filename from the server's Content-Type header (e.g. `application/epub+zip` → `.epub`), applied at probe suggestion, confirmation, and download finalization; unmapped types keep the bare name.
_Avoid_: MIME guessing, type sniffing

**Archive Extraction Phase**:
The `EXTRACTING` state on the DownloadSession, entered after a completed `.zip` download — automatically for attempts that opted in, or on user request from the completion dialog — extracting into a collision-free subfolder via the Archive Extractor; failure keeps the archive and soft-completes.
_Avoid_: Unzip step, decompress stage, inflate phase

**Archive Extractor**:
The libarchive adapter (`archive_extractor.lua`) over KOReader's `ffi/archiver` that extracts archives entry-by-entry with zip-slip and bomb guards, purging the destination on any failure so no half-extracted tree survives.
_Avoid_: Unzipper, archive manager, decompressor

**Collision Handler**:
The interactive flow presenting Overwrite, Auto-Rename (e.g. `file (1).pdf`), or Cancel options when the target filename already exists in the target folder.
_Avoid_: Duplicate manager, conflict resolver

**Pre-Download Confirmation**:
The modal dialog displaying the final save path and editable filename before starting the network transfer.
_Avoid_: Download modal, save prompt

**Pre-Flight Metadata Probe**:
The lightweight header-only network query executed prior to the confirmation dialog to discover redirect locations, RFC 5987 filenames, and content lengths without streaming body data.
_Avoid_: HEAD check, pre-fetch, preliminary scan

**Resilient Socket Transport**:
The custom streaming socket layer capable of gracefully handling non-standard HTTP 1.0 redirect headers (such as bogus Content-Length on 302 responses) and auto-encoding raw whitespace in redirect paths.
_Avoid_: Custom http, raw socket fetcher, socket hack

**Yieldable Socket Transport**:
The poll-loop socket primitive beneath the Resilient Socket Transport that retries every blocking operation (connect, TLS handshake, send, reads) at short intervals, checking the abort signal before each yield so the event loop keeps pumping and cancellation stays live.
_Avoid_: Async sockets, non-blocking layer, evented transport

**Tag Ribbon Paging**:
The sliding window mechanism presenting navigation arrows (◀ / ▶) across subfolder presets when tag count exceeds the physical display width.
_Avoid_: Tag scroller, folder carousel, chip paginator

**Modal Window Container**:
The centered floating frame architecture utilizing `modal = true`, `FrameContainer`, and `MovableContainer` to avoid fullscreen window stack deadlocks on dismissal.
_Avoid_: Fullscreen canvas, overlay window

**Ephemeral State**:
In-memory runtime state (such as the active URL, typed octets, and session history) that is cleared upon closing the plugin to avoid flash storage wear.
_Avoid_: Session cache, temp storage, volatile settings
