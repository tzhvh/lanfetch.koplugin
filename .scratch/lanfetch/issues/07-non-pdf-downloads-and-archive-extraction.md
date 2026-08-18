Type: research
Status: resolved

# Non-PDF Downloads & Optional Archive Extraction

## Question

How should the pipeline accept non-PDF downloads (EPUB/HTML/MD/ZIP/images/…), and where does optional post-download unzipping of `.zip` archives live?

## Answer

Architecture and implementation resolved (rationale: ADR-0002 — archive extraction is a session phase, not an engine stage):

1. **Format-neutral Filename Sanitizer**: `sanitizeFilename` no longer forces `.pdf` — a name's own extension is authoritative (downloading `book.epub` used to produce `book.epub.pdf`). An extensionless name is completed from the response Content-Type via `extensionForContentType` (EPUB, HTML/XHTML, Markdown, plain text, ZIP, CBZ/CBR, DjVu, FB2, MOBI/AZW3, images, Office/JSON/CSV); unmapped types keep the bare name. The fallback name is `download`, not `download.pdf`.
2. **Content-Type threading through the session**: the Pre-Flight Metadata Probe's headers (Content-Type) are captured by the session and passed to the sanitizer at both suggestion time (CONFIRMING payload) and confirm time, so a user-edited extensionless name still gains the right extension. The engine applies the same rule to the real response at download finalize.
3. **`archive_extractor.lua`**: extracts via KOReader's `ffi/archiver` (libarchive) — `Reader:open` → `iterate` → `extractToPath` per entry, the OTA-plugin pattern. Uniform result `{ ok, files, error, aborted }`; any failure (unsafe entry, duplicate path, libarchive error, abort, archive-bomb caps of 2000 entries / 1 GiB uncompressed) purges the destination directory. Lua-level guards reject absolute paths, backslashes, drive letters, and `..` segments on top of libarchive's `ARCHIVE_EXTRACT_SECURE_NODOTDOT`; links/devices are never materialized. The archiver is injectable for headless tests.
4. **EXTRACTING session phase**: entered from a completed `.zip` download in two ways — automatically when the attempt carried `{ unzip = true }` and an extractor is injected, or on user request via `session:extract()` from `COMPLETED` (the success-dialog Unzip action; legal only for a completed, not-yet-successfully-extracted `.zip`, so it doubles as the retry after a failed auto-extraction). Extraction runs in its own coroutine (yield between entries, abort-checked), into a `getUniqueFilename`-collision-free subfolder named after the archive stem. Failure soft-completes: `COMPLETED` with the archive path and `meta.extracted = { ok = false, error }`. Not user-cancellable; `handleClose()` interrupts it via the shared abort flag and the late result is ignored after `CLOSED`. The archive file is kept after successful extraction (`meta.extracted = { ok = true, dir, files }`, outcome path = extraction dir).
5. **Settings & UI**: `auto_unzip` setting (default off) with a toggle under main menu → Download Settings for the hands-free flow. The success dialog is the per-download opt-in: an unextracted `.zip` gets a three-action ButtonDialog — 📦 Unzip (fires `COMPLETED → EXTRACTING`; the dialog re-appears with results), 📂 Open Folder, Stay Here. A non-dismissable "📦 Extracting" message shows during the phase; other completions keep the extension-aware ConfirmBox ("📖 Open" via ReaderUI for KOReader-openable types, "📂 Open Folder" otherwise).

**Tests**: `tests/test_archive_extractor.lua` (fake archiver + real filesystem: safety guards, purge-on-any-failure, abort, caps), engine suite (format neutrality + content-type completion + mock-server EPUB/ZIP downloads), session suite (EXTRACTING matrix: opt-in gating, soft failure, collision uniquifying, teardown inertness), and `tests/smoke_archive_extractor_koreader.lua` — a real-libarchive round trip (including a python-crafted zip-slip archive) run under KOReader's own luajit against `ffi/archiver` + `libarchive.so.13`.
