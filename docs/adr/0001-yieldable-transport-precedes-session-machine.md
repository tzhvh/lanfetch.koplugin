---
status: accepted
---

# Yieldable transport precedes the DownloadSession state machine

The download lifecycle exhibited sequencing defects (frozen UI during connect/TLS/header reads, a cancel that could not land mid-connect, two independent abort channels, a zombie coroutine outliving its dialog), and the tempting fix — wrapping the existing blocking engine in a formal `DownloadSession` state machine — would have formalized the freeze: a beautiful lifecycle around a still-blocking core. We decided the engine's socket transport must become yieldable (short per-socket timeouts, abort-check-then-yield poll loops around connect, TLS handshake, sends, and header reads) **before** the session state machine is built on top of it.

## Sequence

1. Typed terminal funnel in `download_engine` (uniform outcome table, single exit path).
2. Yieldable poll helpers inside the engine, used by both download and the Pre-Flight Metadata Probe.
3. `DownloadSession` with injected engine, scheduler, and state/progress observers, tested against a fake engine.
4. Unify probe and download on one hop module.
5. Collision Handler as a state on the resulting machine.

## Consequences

- CANCEL is real in every state: poll loops check `abort_checker` before yielding, so cancellation lands within one poll interval (~200ms) even during connect.
- Probe failures soft-degrade to the Pre-Download Confirmation with a fallback name; abort is distinct from failure; there is no `FAILED_PROBE` state, and retry is legal only from download-phase `FAILED`.
- The session owns its coroutine and ignores late engine outcomes after `CLOSED`; the engine's terminal funnel handles socket close and temp-file cleanup either way.
