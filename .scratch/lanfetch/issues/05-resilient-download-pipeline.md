Type: research
Status: resolved

# Resilient Download Pipeline & Protocol Fallbacks

## Question

How should the KOReader download pipeline handle HTTP $\to$ HTTPS fallbacks, 30x redirects, `Content-Disposition` header extraction with fallback prompting, and stream chunking with `ltn12.sink.file` and `Trapper`?

## Answer

Architecture and implementation resolved. As-built on branch `download-lifecycle` (rationale: ADR-0001 — yieldable transport precedes the session state machine):

1. **Yieldable Hop Transport (`http_hop.lua`)**: One GET-hop module — URL parse, TCP connect, optional TLS, request send, status line, headers — shared by the Pre-Flight Metadata Probe and the Download Pipeline. Every blocking operation is a poll loop ($200\text{ms}$ granularity, abort checked before each yield) under wall-clock caps (10s connect / 30s read). Redirect budget: 10 hops with a visited-set cycle guard; relative `Location` headers resolved via `socket.url.absolute` with raw spaces escaped to `%20`; Host header carries the port unless it is the scheme default. Failure stages are structured descriptors the engine maps to user-facing messages.
2. **Transparent Protocol Fallback**: On connect failure or HTTP 400 over `http://`, exactly one retry with `https://` (LuaSec `verify = "none"` for LAN self-signed tolerance). Fallback is download-only — the probe soft-degrades instead, because an https-only server must not fail the attempt before the download's fallback can succeed.
3. **Typed Terminal Funnel**: Every `download()` exit returns a uniform outcome table `{ kind, path, meta, error }` (`DownloadEngine.KIND`: completed / aborted / failed; `meta` always a table; `error` nil exactly when kind ≠ failed) through a single `finish()` funnel that owns socket close and `.lanfetch_*.tmp` cleanup. The `"aborted"` magic string and per-branch cleanup rituals are gone.
4. **Filename Extraction & RFC 5987**: Priority: custom filename → `Content-Disposition` (`filename*=` RFC 5987 UTF-8, quoted, unquoted) → URL path → redirect `Location` basename. Sanitizer strips illegal FAT32/Android characters, trims dots/spaces, ensures `.pdf`, caps at 200 characters. Collisions currently auto-rename to `name (1).ext`; the interactive Collision Handler (Overwrite / Auto-Rename / Cancel) is future work awaiting a `COLLIDING` state on the session machine.
5. **Streaming to Disk & UI Non-blocking**: Streams 8KB chunks via the hop's `poll_receive_chunk` directly into `.lanfetch_<time>_<rand>.tmp` in the destination folder (same-filesystem atomic `os.rename` on completion). Progress callbacks fire per chunk; the abort flag is polled before every yield; stalls poll-and-yield instead of freezing the UI. The UI coroutine is owned by the session, not the dialog.
6. **DownloadSession (`download_session.lua`)**: The state machine at the dialog↔engine seam — `IDLE → PROBING → CONFIRMING → DOWNLOADING → COMPLETED | FAILED | ABORTED`, `CANCELING` unwinds engine work to `ABORTED`, any state → `CLOSED`. Illegal edges are no-ops (the double-tap START guard is the transition table itself); one cancel path; retry only from download-phase FAILED reusing confirmed URL/filename; `handleClose()` marks CLOSED synchronously and ignores the late engine outcome while the funnel still cleans up. Probe failures never throw (pcall) and soft-degrade to CONFIRMING with a fallback name. Orphan temp files are swept at attempt start.
