Type: research
Status: resolved

# Resilient Download Pipeline & Protocol Fallbacks

## Question

How should the KOReader download pipeline handle HTTP $\to$ HTTPS fallbacks, 30x redirects, `Content-Disposition` header extraction with fallback prompting, and stream chunking with `ltn12.sink.file` and `Trapper`?

## Answer

Architecture and implementation resolved:
1. **Redirect Engine**: Explicit redirect loop up to 10 redirects, supporting 301, 302, 303 (method rewrites to GET), 307, and 308. Relative `Location` headers are resolved against base URL using `socket.url.absolute`.
2. **Transparent Protocol Fallback**: Starts with explicit scheme (or `http://`). If connection refused, timed out (10s connect / 30s chunk read), or returns HTTP 400, automatically retries opposite scheme (http $\leftrightarrow$ https) using LuaSec `verify = "none"` for LAN self-signed certificate tolerance.
3. **Filename Extraction & RFC 5987**: Extraction priority: (1) URL path, (2) `Content-Disposition` header parsing `filename*=` (RFC 5987 UTF-8 unescaped) and `filename=`, (3) Fallback prompt `download.pdf`. Sanitizer strips illegal FAT32/Android chars, trims dots/spaces, ensures `.pdf` extension, and caps length at 200 chars.
4. **Streaming to Disk & UI Non-blocking**: Streams via custom `ltn12.sink.file` directly to an atomic `.tmp` file in destination folder. Emits progress callbacks (bytes received, percentage, transfer speed) and checks abort signal on each chunk. User cancellation or network failure triggers immediate file handle closure and partial file deletion (`os.remove`). Success triggers atomic `os.rename`. Wrapped with `Trapper:wrap` and protected by `socketutil:set_timeout(10, 30)`.
