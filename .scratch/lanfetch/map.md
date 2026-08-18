## Destination

Complete architecture and technical specification for the KOReader LAN PDF Downloader plugin (`lanfetch.koplugin`), detailing the dual-mode e-ink UI with custom IPv4 keypad & octet tabber, portable LAN subnet autodetection (Android & Linux), hierarchical preset folder selector, and streaming HTTP/HTTPS download pipeline.

## Notes

- Domain: KOReader e-reader plugin (LuaJIT, e-ink BlitBuffer UI, LuaSocket, Android/Linux POSIX)
- Skills to consult: `koreader-plugin-creator`, `domain-modeling`, `grilling`, `prototype`, `research`
- Standing preferences:
  - Dual-mode input: First-class LAN Mode (segmented IPv4 keypad) + Alphanumeric Mode (KOReader system keyboard fallback).
  - Subnet autodetection enabled by default with zero shell forks (UDP socket probe).
  - Android compatibility verified across all networking and storage paths.
  - Strict ephemeral state for URLs/octets to minimize e-reader flash I/O.
  - High-contrast e-ink rendering with partial screen dirty rects.
  - Direct streaming to disk (8 KB chunks over the yieldable `http_hop` transport) with redirect following and `Content-Disposition` header parsing; the attempt lifecycle is governed by the `DownloadSession` state machine (ADR-0001).

## Decisions so far

<!-- the index — one line per closed ticket: enough to judge relevance, then zoom the link for the detail the ticket holds -->

- [Specification: LAN PDF Downloader for KOReader](spec.md) — Comprehensive technical specification detailing the complete dual-mode input architecture, zero-packet subnet probe, pre-flight metadata probe, resilient raw socket transport, paged tag ribbon, and native modal dialog container.
- [Portable Subnet Probe & Android Compatibility](issues/01-portable-subnet-probe.md) — Non-blocking dummy connected UDP socket queries kernel routing table across Android and Linux without root, packets, or shell forks.
- [Octet Tabber State Machine & E-Ink Selection Control](issues/02-octet-tabber-state-machine.md) — Discrete token state machine enables Tab cycling, digit overwrite on whole selection, arrow deselection, and backspace substring wipe with high-contrast e-ink partial redraws.
- [Dual-Mode Keyboard Coexistence & Alphanumeric Handoff](issues/03-dual-mode-keyboard-coexistence.md) — Bidirectional URL parser enables seamless handoff between the custom full-screen LAN keypad and KOReader's native InputDialog/virtual keyboard.
- [Hierarchical Folder Presets & Tag Switcher](issues/04-hierarchical-folder-presets.md) — Persistent base directory plus hierarchical subfolder presets rendered as a high-contrast tag ribbon with recursive on-demand directory creation.
- [Resilient Download Pipeline & Protocol Fallbacks](issues/05-resilient-download-pipeline.md) — Yieldable `http_hop` transport (poll-loop connect/TLS/reads, abort before every yield) under a `DownloadSession` state machine: 10-hop redirect handling, transparent HTTP/HTTPS fallback, RFC 5987 parsing, typed terminal outcomes, atomic direct-to-disk .tmp streaming, and CANCEL that lands in every phase (ADR-0001).
- [Onboarding Flow & Ephemeral State Lifecycle](issues/06-onboarding-and-ephemeral-lifecycle.md) — 2-step first-run wizard, strict in-memory RAM URL state with zero flash wear, and post-download reader invocation.
- [Non-PDF Downloads & Optional Archive Extraction](issues/07-non-pdf-downloads-and-archive-extraction.md) — Format-neutral filenames (own extension kept; extensionless names completed from Content-Type) plus the `EXTRACTING` session phase for completed .zip archives via `archive_extractor.lua` over `ffi/archiver`/libarchive — zip-slip and bomb guards, purge-on-any-failure, soft-complete keeping the archive; entered by the `auto_unzip` setting or per-download from the success dialog's Unzip action (ADR-0002).

## Not yet specified

<!-- All architectural fog has graduated and resolved. Ready for handoff and implementation. -->

## Out of scope

- Cloud storage synchronization (WebDAV, Nextcloud, Calibre Content Server API) — focus is strictly bare IP/URL LAN downloads.
- Custom PDF rendering or annotation modifications inside KOReader.
