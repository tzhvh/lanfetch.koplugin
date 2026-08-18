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
    local calls = { download = {}, probe = {}, sweeps = 0 }
    local engine = {
        KIND = { COMPLETED = "completed", ABORTED = "aborted", FAILED = "failed" },
        extractFilenameFromUrl = function() return behavior.url_name end,
        sanitizeFilename = function(name)
            return (name and name ~= "" and name or "download.pdf"):gsub("%s+", "_")
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
                local name, final_url, size = behavior.probe_result(url)
                return name, final_url, size
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

local function make_session(engine)
    local states, progress = {}, {}
    local schedule, pump = make_scheduler()
    local session = DownloadSession.new{
        engine = engine,
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
    assert_eq(states2[#states2].payload.suggested_name, "download.pdf", "fallback name after probe crash")
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

if failures > 0 then
    print(string.format("%d test(s) FAILED", failures))
    os.exit(1)
end
print("All DownloadSession state machine tests passed.")
