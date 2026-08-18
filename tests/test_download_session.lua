-- tests/test_download_session.lua
-- Drives the DownloadSession state machine headless: fake engine, manual scheduler.
--   lua tests/test_download_session.lua
package.path = "lanfetch.koplugin/?.lua;" .. package.path
local DownloadSession = require("download_session")
local STATE = DownloadSession.STATE

local failures = 0
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

-- Manual scheduler: queue of step functions, pumped explicitly.
local function make_scheduler()
    local queue = {}
    local function pump(max_steps)
        local steps = 0
        while #queue > 0 and steps < (max_steps or 50) do
            table.remove(queue, 1)()
            steps = steps + 1
        end
        return steps
    end
    return function(fn) table.insert(queue, fn) end, pump
end

-- Fake engine: records calls, runs scripted behavior.
local function make_fake_engine(behavior)
    behavior = behavior or {}
    local calls = { download = {}, probe = {}, sweeps = 0, sanitizes = {}, uniques = {} }
    local engine = {
        KIND = { COMPLETED = "completed", ABORTED = "aborted", FAILED = "failed" },
        extractFilenameFromUrl = function() return behavior.url_name end,
        sanitizeFilename = function(name, fallback, content_type)
            calls.sanitizes[#calls.sanitizes + 1] = { name = name, fallback = fallback, content_type = content_type }
            return (name and name ~= "" and name or fallback or "download"):gsub("%s+", "_")
        end,
        getUniqueFilename = function(dir, base)
            calls.uniques[#calls.uniques + 1] = { dir = dir, base = base }
            if behavior.collide_stub then return base .. " (1)" end
            return base
        end,
        sweepOrphanTempFiles = function() calls.sweeps = calls.sweeps + 1; return 0 end,
        probeRemoteMetadata = function(url, timeout, abort, yield)
            calls.probe[#calls.probe + 1] = url
            -- Yieldable fake: yields probe_steps times, abortable at each yield
            for _ = 1, (behavior.probe_steps or 0) do
                if abort and abort() then return nil, url, nil end
                yield()
            end
            if behavior.probe_error then error("probe blew up") end
            if behavior.probe_result then
                local name, final_url, size, headers = behavior.probe_result(url)
                return name, final_url, size, headers
            end
            return nil, url, nil
        end,
        download = function(url, dir, opts, progress, abort, yield)
            calls.download[#calls.download + 1] = { url = url, dir = dir, opts = opts }
            return behavior.download_script(progress, abort, yield)
        end,
    }
    return engine, calls
end

-- Fake extractor: records calls, optionally yields (extract runs in a
-- coroutine too) and can fail or throw.
local function make_fake_extractor(script)
    script = script or {}
    local calls = {}
    local extractor = {
        extract = function(zip_path, dest_dir, opts)
            calls[#calls + 1] = { zip_path = zip_path, dest_dir = dest_dir, opts = opts }
            if script.throw then error("extractor blew up") end
            for _ = 1, (script.steps or 0) do
                if opts.abort_checker and opts.abort_checker() then
                    return { ok = false, files = 0, error = "canceled", aborted = true }
                end
                opts.yield_fn()
            end
            if script.result ~= nil then return script.result end
            return { ok = true, files = 3, error = nil, aborted = false }
        end,
    }
    return extractor, calls
end

local function make_session(engine, extractor)
    local states, progress = {}, {}
    local schedule, pump = make_scheduler()
    local session = DownloadSession.new{
        engine = engine,
        extractor = extractor,
        schedule = schedule,
        on_state = function(state, payload) states[#states + 1] = { state = state, payload = payload } end,
        on_progress = function(bytes, total, pct, speed)
            progress[#progress + 1] = { bytes = bytes, total = total }
        end,
    }
    return session, states, progress, pump
end

local function last(states) return states[#states] and states[#states].state end

print("== DownloadSession: URL-filename path skips probe ==")
do
    local engine, calls = make_fake_engine{
        url_name = "direct.pdf",
        download_script = function(progress)
            progress(10, 10, 100, 1000)
            return { kind = "completed", path = "/d/direct.pdf", meta = { size = 10 }, error = nil }
        end,
    }
    local session, states, progress, pump = make_session(engine)
    assert_eq(session:start("http://h:1/direct.pdf", "/d"), true, "start accepted")
    pump()
    assert_eq(session.state, STATE.CONFIRMING, "URL filename → straight to CONFIRMING")
    assert_eq(#calls.probe, 0, "no probe for URL-with-filename")
    assert_eq(calls.sweeps, 1, "orphan tmp swept at attempt start")
    assert_eq(states[1].payload.suggested_name, "direct.pdf", "suggested name from URL")
    assert_eq(session:confirm("my file"), true, "confirm accepted")
    pump()
    assert_eq(session.state, STATE.COMPLETED, "completed")
    assert_eq(session.outcome.path, "/d/direct.pdf", "outcome carries path")
    assert_eq(calls.download[1].opts.custom_filename, "my_file", "confirmed name sanitized and passed")
    assert_eq(#progress, 1, "progress forwarded")
    assert_eq(last(states), STATE.COMPLETED, "on_state ends COMPLETED")
end

print("== DownloadSession: probe path, soft-degrade, confirm ==")
do
    local engine, calls = make_fake_engine{
        url_name = nil,
        probe_steps = 2,
        probe_result = function() return "probed.pdf", "http://h:1/final.pdf", 4321 end,
        download_script = function(progress)
            progress(1, 2, 50, 10)
            return { kind = "completed", path = "/d/probed.pdf", meta = { size = 2 }, error = nil }
        end,
    }
    local session, states, _, pump = make_session(engine)
    session:start("http://h:1/", "/d")
    pump()
    assert_eq(session.state, STATE.CONFIRMING, "probe → CONFIRMING")
    assert_eq(states[#states].payload.suggested_name, "probed.pdf", "probe name suggested")
    assert_eq(states[#states].payload.size, 4321, "probe size in payload")
    assert_eq(states[#states].payload.final_url, "http://h:1/final.pdf", "redirect-resolved URL in payload")
    session:confirm("probed.pdf")
    pump()
    assert_eq(session.state, STATE.COMPLETED, "completed via probe path")
    assert_eq(calls.download[1].url, "http://h:1/final.pdf", "download uses probe-resolved URL")

    -- Probe that throws soft-degrades to CONFIRMING with fallback name
    local engine2 = make_fake_engine{
        url_name = nil,
        probe_steps = 1,
        probe_error = true,
        download_script = function() return { kind = "failed", path = nil, meta = {}, error = "x" } end,
    }
    local session2, states2, _, pump2 = make_session(engine2)
    session2:start("http://h:1/", "/d")
    pump2()
    assert_eq(session2.state, STATE.CONFIRMING, "probe crash soft-degrades")
    assert_eq(states2[#states2].payload.suggested_name, "download", "fallback name after probe crash (no forced .pdf)")

    -- A probe that only learned the Content-Type still completes the name
    local engine3, calls3 = make_fake_engine{
        url_name = nil,
        probe_steps = 1,
        probe_result = function(url) return "book", url .. "final", 10, { ["content-type"] = "application/epub+zip" } end,
        download_script = function() return { kind = "completed", path = "/d/book.epub", meta = {}, error = nil } end,
    }
    local session3, states3, _, pump3 = make_session(engine3)
    session3:start("http://h:1/", "/d")
    pump3()
    assert_eq(session3.state, STATE.CONFIRMING, "probe with content type reaches CONFIRMING")
    assert_eq(calls3.sanitizes[1].name, "book", "probe name handed to sanitizer")
    assert_eq(calls3.sanitizes[1].content_type, "application/epub+zip", "probe content type threaded to sanitizer")
    session3:confirm("book")
    pump3()
    assert_eq(calls3.sanitizes[2].content_type, "application/epub+zip", "confirm reuses probe content type")
    assert_eq(calls3.download[1].opts.custom_filename, "book", "confirmed name passed through")
end

print("== DownloadSession: guards — double-tap, illegal transitions ==")
do
    local engine, calls = make_fake_engine{
        url_name = "f.pdf",
        download_script = function(progress, abort, yield)
            while not abort() do yield() end -- hang until cancelled
            return { kind = "aborted", path = nil, meta = {}, error = nil }
        end,
    }
    local session, states, _, pump = make_session(engine)
    session:start("http://h:1/f.pdf", "/d")
    pump()
    session:confirm("f.pdf")
    pump(3) -- let download start and hang
    assert_eq(session.state, STATE.DOWNLOADING, "downloading")
    assert_eq(session:start("http://other:1/x.pdf", "/d"), false, "second START refused")
    assert_eq(#calls.download, 1, "no second engine download")
    assert_eq(session:confirm("again"), false, "confirm refused outside CONFIRMING")
    assert_eq(session:retry(), false, "retry refused while DOWNLOADING")
    assert_eq(session.state, STATE.DOWNLOADING, "state unchanged by illegal events")
    -- cancel unwinds to ABORTED
    assert_eq(session:cancel(), true, "cancel accepted")
    pump()
    assert_eq(session.state, STATE.ABORTED, "cancel → CANCELING → ABORTED")
    -- retry illegal from ABORTED
    assert_eq(session:retry(), false, "retry refused from ABORTED (no FAILED_PROBE/download confirmed reuse only)")
end

print("== DownloadSession: cancel from CONFIRMING returns to IDLE ==")
do
    local engine = make_fake_engine{ url_name = "f.pdf", download_script = function() end }
    local session, states, _, pump = make_session(engine)
    session:start("http://h:1/f.pdf", "/d")
    pump()
    session:cancel()
    assert_eq(session.state, STATE.IDLE, "confirm-cancel → IDLE synchronously")
    assert_eq(last(states), STATE.IDLE, "on_state notified IDLE")
end

print("== DownloadSession: FAILED → retry reuses confirmed args ==")
do
    local engine, calls = make_fake_engine{
        url_name = "f.pdf",
        download_script = function() return { kind = "failed", path = nil, meta = {}, error = "server 500" } end,
    }
    local session, states, _, pump = make_session(engine)
    session:start("http://h:1/f.pdf", "/d")
    pump()
    session:confirm("name.pdf")
    pump()
    assert_eq(session.state, STATE.FAILED, "failed after download error")
    assert_eq(session.outcome.error, "server 500", "outcome error surfaced")
    assert_eq(session:retry(), true, "retry accepted from FAILED")
    pump()
    assert_eq(session.state, STATE.FAILED, "scripted failure again")
    assert_eq(#calls.download, 2, "engine called twice")
    assert_eq(calls.download[2].opts.custom_filename, "name.pdf", "retry reuses confirmed filename")
    assert_eq(calls.download[2].url, calls.download[1].url, "retry reuses confirmed URL")
end

print("== DownloadSession: runtime error in engine normalizes to FAILED ==")
do
    local engine = make_fake_engine{
        url_name = "f.pdf",
        download_script = function() error("kaboom") end,
    }
    local session, _, _, pump = make_session(engine)
    session:start("http://h:1/f.pdf", "/d")
    pump()
    session:confirm("f.pdf")
    pump()
    assert_eq(session.state, STATE.FAILED, "runtime error → FAILED")
    assert_eq(session.outcome.error:find("kaboom", 1, true) ~= nil, true, "runtime error message preserved")
end

print("== DownloadSession: handleClose during DOWNLOADING — CLOSED now, outcome ignored ==")
do
    local engine, calls = make_fake_engine{
        url_name = "f.pdf",
        download_script = function(progress, abort, yield)
            while not abort() do yield() end
            return { kind = "completed", path = "/d/late.pdf", meta = {}, error = nil }
        end,
    }
    local session, states, progress, pump = make_session(engine)
    session:start("http://h:1/f.pdf", "/d")
    pump()
    session:confirm("f.pdf")
    pump(3)
    assert_eq(session.state, STATE.DOWNLOADING, "downloading before close")
    session:handleClose()
    assert_eq(session.state, STATE.CLOSED, "CLOSED set synchronously")
    pump() -- engine unwinds (abort → returns completed), outcome must be ignored
    assert_eq(session.state, STATE.CLOSED, "late COMPLETED outcome ignored")
    assert_eq(last(states), STATE.CLOSED, "no state notifications after CLOSED")
    assert_eq(#progress, 0, "no progress after CLOSED")
    assert_eq(session:start("http://h:1/g.pdf", "/d"), false, "CLOSED is inert")
    assert_eq(session:cancel(), false, "CLOSED ignores cancel")
end

print("== DownloadSession: cancel during PROBING aborts fast ==")
do
    local engine = make_fake_engine{
        url_name = nil,
        probe_steps = 100,
        probe_result = function() return "late.pdf", "http://h:1/x", 1 end,
        download_script = function() end,
    }
    local session, _, _, pump = make_session(engine)
    session:start("http://h:1/", "/d")
    pump(3) -- probe spinning, yielding
    assert_eq(session.state, STATE.PROBING, "probing")
    session:cancel()
    assert_eq(session.state, STATE.CANCELING, "CANCELING entered synchronously")
    pump()
    assert_eq(session.state, STATE.ABORTED, "probe unwind → ABORTED")
end

print("== DownloadSession: opt-in zip extraction — DOWNLOADING → EXTRACTING → COMPLETED ==")
do
    local engine = make_fake_engine{
        url_name = "bundle.zip",
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip",
                     meta = { filename = "bundle.zip", size = 5, content_type = "application/zip" }, error = nil }
        end,
    }
    local extractor, xcalls = make_fake_extractor{ steps = 2 } -- yieldable extraction
    local session, states, _, pump = make_session(engine, extractor)
    session:start("http://h:1/bundle.zip", "/d", { unzip = true })
    pump()
    session:confirm("bundle.zip")
    pump(3)
    assert_eq(session.state, STATE.EXTRACTING, "engine COMPLETED on zip with unzip → EXTRACTING")
    assert_eq(states[#states].payload.dest_dir, "/d/bundle", "dest dir named after archive stem")
    pump(10) -- extraction coroutine yields twice, then returns
    assert_eq(session.state, STATE.COMPLETED, "extraction lands in COMPLETED")
    assert_eq(session.outcome.path, "/d/bundle", "outcome path is the extraction dir")
    assert_eq(session.outcome.meta.extracted.ok, true, "extraction recorded ok")
    assert_eq(session.outcome.meta.extracted.files, 3, "extracted file count surfaced")
    assert_eq(xcalls[1].zip_path, "/d/bundle.zip", "extractor got the archive path")
    assert_eq(xcalls[1].dest_dir, "/d/bundle", "extractor got the dest dir")
    local saw_extracting = false
    for _, s in ipairs(states) do
        if s.state == STATE.EXTRACTING then saw_extracting = true end
    end
    assert_eq(saw_extracting, true, "EXTRACTING observable via on_state")
end

print("== DownloadSession: extraction skipped without opt-in or for non-zip ==")
do
    -- zip downloaded but unzip option off (the default)
    local engine = make_fake_engine{
        url_name = "bundle.zip",
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip", meta = { filename = "bundle.zip" }, error = nil }
        end,
    }
    local extractor, xcalls = make_fake_extractor{}
    local session, states, _, pump = make_session(engine, extractor)
    session:start("http://h:1/bundle.zip", "/d")
    pump()
    session:confirm("bundle.zip")
    pump()
    assert_eq(session.state, STATE.COMPLETED, "no unzip option → straight COMPLETED")
    assert_eq(#xcalls, 0, "extractor never called")

    -- unzip on, but the download is a PDF
    local engine2 = make_fake_engine{
        url_name = "paper.pdf",
        download_script = function()
            return { kind = "completed", path = "/d/paper.pdf", meta = { filename = "paper.pdf" }, error = nil }
        end,
    }
    local extractor2, xcalls2 = make_fake_extractor{}
    local session2, states2, _, pump2 = make_session(engine2, extractor2)
    session2:start("http://h:1/paper.pdf", "/d", { unzip = true })
    pump2()
    session2:confirm("paper.pdf")
    pump2()
    assert_eq(session2.state, STATE.COMPLETED, "non-zip → straight COMPLETED even with unzip on")
    assert_eq(#xcalls2, 0, "extractor never called for non-zip")
    for _, s in ipairs(states2) do
        assert_eq(s.state ~= STATE.EXTRACTING, true, "no EXTRACTING state for non-zip")
    end

    -- zip container formats that must stay intact (.epub) are not extracted
    local engine3 = make_fake_engine{
        url_name = "book.epub",
        download_script = function()
            return { kind = "completed", path = "/d/book.epub", meta = { filename = "book.epub" }, error = nil }
        end,
    }
    local extractor3, xcalls3 = make_fake_extractor{}
    local session3, _, _, pump3 = make_session(engine3, extractor3)
    session3:start("http://h:1/book.epub", "/d", { unzip = true })
    pump3()
    session3:confirm("book.epub")
    pump3()
    assert_eq(session3.state, STATE.COMPLETED, "epub kept intact")
    assert_eq(#xcalls3, 0, "extractor never called for epub")
end

print("== DownloadSession: extraction failure soft-completes, archive kept ==")
do
    -- Extractor reports failure: download itself succeeded, so the session
    -- completes with the archive path and a warning in meta.extracted.
    local engine = make_fake_engine{
        url_name = "bundle.zip",
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip", meta = { filename = "bundle.zip" }, error = nil }
        end,
    }
    local extractor = make_fake_extractor{ result = { ok = false, files = 1, error = "corrupt archive", aborted = false } }
    local session, _, _, pump = make_session(engine, extractor)
    session:start("http://h:1/bundle.zip", "/d", { unzip = true })
    pump()
    session:confirm("bundle.zip")
    pump()
    assert_eq(session.state, STATE.COMPLETED, "extraction failure still COMPLETED")
    assert_eq(session.outcome.path, "/d/bundle.zip", "archive path is the outcome path")
    assert_eq(session.outcome.meta.extracted.ok, false, "failure recorded")
    assert_eq(session.outcome.meta.extracted.error, "corrupt archive", "extractor error surfaced")

    -- Extractor throws: normalized to the same soft-complete shape
    local engine2 = make_fake_engine{
        url_name = "bundle.zip",
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip", meta = { filename = "bundle.zip" }, error = nil }
        end,
    }
    local extractor2 = make_fake_extractor{ throw = true }
    local session2, _, _, pump2 = make_session(engine2, extractor2)
    session2:start("http://h:1/bundle.zip", "/d", { unzip = true })
    pump2()
    session2:confirm("bundle.zip")
    pump2()
    assert_eq(session2.state, STATE.COMPLETED, "extractor crash still COMPLETED")
    assert_eq(session2.outcome.meta.extracted.ok, false, "crash recorded as failure")
    assert_eq(session2.outcome.meta.extracted.error:find("blew up", 1, true) ~= nil, true, "crash message preserved")
end

print("== DownloadSession: extraction dest dir uniquified on collision ==")
do
    local engine, calls = make_fake_engine{
        url_name = "bundle.zip",
        collide_stub = true, -- engine.getUniqueFilename reports a collision
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip", meta = { filename = "bundle.zip" }, error = nil }
        end,
    }
    local extractor, xcalls = make_fake_extractor{}
    local session, states, _, pump = make_session(engine, extractor)
    session:start("http://h:1/bundle.zip", "/d", { unzip = true })
    pump()
    session:confirm("bundle.zip")
    pump()
    assert_eq(calls.uniques[1].base, "bundle", "stem offered to getUniqueFilename")
    assert_eq(states[#states - 1].payload.dest_dir, "/d/bundle (1)", "collision-free dest dir chosen")
    assert_eq(xcalls[1].dest_dir, "/d/bundle (1)", "extractor got the collision-free dir")
end

print("== DownloadSession: handleClose during EXTRACTING — CLOSED, late result ignored ==")
do
    local engine = make_fake_engine{
        url_name = "bundle.zip",
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip", meta = { filename = "bundle.zip" }, error = nil }
        end,
    }
    local extractor = make_fake_extractor{ steps = 100 } -- spins until aborted
    local session, states, _, pump = make_session(engine, extractor)
    session:start("http://h:1/bundle.zip", "/d", { unzip = true })
    pump()
    session:confirm("bundle.zip")
    pump(3)
    assert_eq(session.state, STATE.EXTRACTING, "extracting before close")
    assert_eq(session:cancel(), false, "cancel is a no-op during EXTRACTING (not user-cancellable)")
    session:handleClose()
    assert_eq(session.state, STATE.CLOSED, "CLOSED set synchronously")
    pump(20) -- extractor unwinds via the abort flag; outcome must be ignored
    assert_eq(session.state, STATE.CLOSED, "late extraction result ignored")
    assert_eq(last(states), STATE.CLOSED, "no state notifications after CLOSED")
    assert_eq(session.outcome.meta.extracted, nil, "outcome untouched by aborted extraction")
end

print("== DownloadSession: user-initiated extract from COMPLETED (success-dialog opt-in) ==")
do
    -- A zip downloaded without the unzip option: extract() starts the phase
    local engine = make_fake_engine{
        url_name = "bundle.zip",
        download_script = function()
            return { kind = "completed", path = "/d/bundle.zip", meta = { filename = "bundle.zip" }, error = nil }
        end,
    }
    local extractor, xcalls = make_fake_extractor{ steps = 1 }
    local session, states, _, pump = make_session(engine, extractor)
    session:start("http://h:1/bundle.zip", "/d") -- unzip NOT opted in
    pump()
    session:confirm("bundle.zip")
    pump()
    assert_eq(session.state, STATE.COMPLETED, "no auto extraction without the option")
    assert_eq(#xcalls, 0, "extractor idle until user opts in")

    assert_eq(session:extract(), true, "user extract accepted from COMPLETED")
    assert_eq(session.state, STATE.EXTRACTING, "user extract enters EXTRACTING")
    pump(10)
    assert_eq(session.state, STATE.COMPLETED, "back to COMPLETED after extraction")
    assert_eq(session.outcome.path, "/d/bundle", "outcome path repointed at extraction dir")
    assert_eq(session.outcome.meta.extracted.ok, true, "extraction recorded")
    assert_eq(session:extract(), false, "second extract refused once extracted ok")

    -- Guards: non-zip outcomes, wrong states, missing extractor
    local engine_pdf = make_fake_engine{
        url_name = "paper.pdf",
        download_script = function()
            return { kind = "completed", path = "/d/paper.pdf", meta = { filename = "paper.pdf" }, error = nil }
        end,
    }
    local session_pdf, _, _, pump_pdf = make_session(engine_pdf, make_fake_extractor{})
    session_pdf:start("http://h:1/paper.pdf", "/d")
    pump_pdf()
    session_pdf:confirm("paper.pdf")
    pump_pdf()
    assert_eq(session_pdf.state, STATE.COMPLETED, "pdf download completed")
    assert_eq(session_pdf:extract(), false, "extract refused for non-zip outcome")
    assert_eq(session_pdf.state, STATE.COMPLETED, "state unchanged by refused extract")

    local engine2 = make_fake_engine{
        url_name = "b.zip",
        download_script = function(progress, abort, yield)
            while not abort() do yield() end
            return { kind = "aborted", path = nil, meta = {}, error = nil }
        end,
    }
    local session2, _, _, pump2 = make_session(engine2, make_fake_extractor{})
    session2:start("http://h:1/b.zip", "/d", { unzip = true })
    pump2()
    session2:confirm("b.zip")
    pump2(3)
    assert_eq(session2.state, STATE.DOWNLOADING, "downloading")
    assert_eq(session2:extract(), false, "extract refused outside COMPLETED")

    local engine3 = make_fake_engine{
        url_name = "b.zip",
        download_script = function()
            return { kind = "completed", path = "/d/b.zip", meta = { filename = "b.zip" }, error = nil }
        end,
    }
    local session3, _, _, pump3 = make_session(engine3) -- no extractor injected
    session3:start("http://h:1/b.zip", "/d")
    pump3()
    session3:confirm("b.zip")
    pump3()
    assert_eq(session3.state, STATE.COMPLETED, "download completed without extractor")
    assert_eq(session3:extract(), false, "extract refused without an extractor")

    -- Failed auto-extraction leaves the archive extractable again from the dialog
    local engine4 = make_fake_engine{
        url_name = "c.zip",
        download_script = function()
            return { kind = "completed", path = "/d/c.zip", meta = { filename = "c.zip" }, error = nil }
        end,
    }
    local extractor4 = make_fake_extractor{ result = { ok = false, files = 0, error = "corrupt", aborted = false } }
    local session4, _, _, pump4 = make_session(engine4, extractor4)
    session4:start("http://h:1/c.zip", "/d", { unzip = true })
    pump4()
    session4:confirm("c.zip")
    pump4()
    assert_eq(session4.state, STATE.COMPLETED, "auto extraction failure soft-completed")
    assert_eq(session4:extract(), true, "retry-extract allowed after failed extraction")
end

if failures > 0 then
    print(string.format("%d test(s) FAILED", failures))
    os.exit(1)
end
print("All DownloadSession state machine tests passed.")
