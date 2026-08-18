---
status: accepted
---

# Archive extraction is a session phase, not an engine stage

Generalizing the pipeline beyond PDF (any extension kept; extensionless names completed from the response Content-Type) made `.zip` a first-class download result, which raised the question of where optional unzipping belongs. Three homes were candidates: inside `DownloadEngine.download()` after the rename, as a dialog-side step after `COMPLETED`, or as a new `EXTRACTING` state on `DownloadSession`. Putting it in the engine would couple an HTTP streaming module to libarchive and break its uniform one-file outcome; doing it in the dialog would put work with real failure/cleanup semantics outside the lifecycle that exists precisely to own those. We decided extraction is a **phase of the session lifecycle** (`DOWNLOADING → EXTRACTING → COMPLETED`), driven through an injected extractor so the session stays KOReader-independent and testable with a fake.

## Sequence

1. Format-neutral `sanitizeFilename` in the engine (name's own extension is authoritative; Content-Type completes extensionless names only) with `extensionForContentType` and the probe threading its Content-Type through the session to both suggestion and confirm.
2. `archive_extractor.lua` — the libarchive adapter (`ffi/archiver` Reader/iterate/extractToPath, the same pattern as plugin OTA flows) with a uniform result table, one-purge-on-any-failure exit rule, Lua-level zip-slip + duplicate-entry guards on top of libarchive's `SECURE_NODOTDOT`, and entry-count/total-size caps. The archiver is injectable; on device it is lazily required.
3. `EXTRACTING` on the `DownloadSession` machine: entered only on a completed `.zip` (by sanitized filename — `.epub`/`.cbz` are zip containers the reader must keep intact) when the attempt opted in via `unzip`; extraction runs in its own spawned coroutine yielding between entries.

## Consequences

- Extraction failure never fails the attempt: the archive is already safely on disk, so the session soft-completes with the archive path and the error in `meta.extracted` — the user never loses a finished download to a bad archive.
- `EXTRACTING` is reachable both automatically (the `auto_unzip` attempt option) and on user request: a legal `COMPLETED → EXTRACTING` edge (`session:extract()`) backs the success dialog's Unzip action, making extraction a per-download opt-in and the natural retry after a failed auto-extraction. `COMPLETED` is the only source state, and only for a not-yet-successfully-extracted `.zip`.
- Extraction is not user-cancellable (a short local operation, matching OTA flows); only teardown interrupts it, through the same abort flag the engine uses, and the extractor purges the partial directory either way.
- The terminal outcome contract is unchanged in shape: `COMPLETED` still carries `path` + `meta`; a successful extraction repoints `path` at the extraction directory and records `meta.extracted = { ok, dir, files }`.
- The zip itself is kept after successful extraction (never silently delete user data); a delete-after-extract option can layer on later without touching the machine.
