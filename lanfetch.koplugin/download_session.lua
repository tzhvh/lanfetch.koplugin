--[[--
DownloadSession: the state machine governing one download attempt from START to
terminal outcome, placed at the seam between the LanFetchDialog and the
DownloadEngine.

The session owns transition legality, the single CANCEL path, retry, and teardown.
It is KOReader-independent: the engine, the scheduler (one step of a coroutine),
and the state/progress observers are injected, so tests drive it headless with a
fake engine and a manual scheduler.

States:
    IDLE → PROBING → CONFIRMING → DOWNLOADING → COMPLETED | FAILED | ABORTED
                            ↘ CANCELING → ABORTED
    any state → CLOSED (dialog teardown; late engine outcomes are ignored)

Probe failures soft-degrade to CONFIRMING with a fallback name (the engine's
protocol fallback only runs during download, so a failed probe must not block a
download that could still succeed). Retry is legal only from FAILED, which is
download-phase only — probing never fails terminally.
--]]--

local DownloadSession = {}

DownloadSession.STATE = {
    IDLE = "idle",
    PROBING = "probing",
    CONFIRMING = "confirming",
    DOWNLOADING = "downloading",
    CANCELING = "canceling",
    COMPLETED = "completed",
    FAILED = "failed",
    ABORTED = "aborted",
    CLOSED = "closed",
}

local STATE = DownloadSession.STATE
local KIND_COMPLETED = "completed"
local KIND_ABORTED = "aborted"

-- Internal event names (edges of the machine). Illegal edges are ignored —
-- that is the guard semantics: a second START while active is a no-op.
local E = {
    START = "start",
    PROBE_RESULT = "probe_result",
    PROBE_RETURNED = "probe_returned",
    CONFIRM_OK = "confirm_ok",
    CANCEL = "cancel",
    DOWNLOAD_RETURNED = "download_returned",
    RETRY = "retry",
    CLOSE = "close",
}

--- Construction: DownloadSession.new{ engine = DownloadEngine, schedule = fn,
--- on_state = fn(state, payload), on_progress = fn(bytes, total, pct, speed) }
--- All observers optional; engine and schedule required.
function DownloadSession.new(deps)
    assert(deps and deps.engine, "DownloadSession: engine dependency required")
    assert(deps.schedule, "DownloadSession: schedule dependency required")
    local self = {
        engine = deps.engine,
        schedule = deps.schedule,
        on_state = deps.on_state,
        on_progress = deps.on_progress,
        state = STATE.IDLE,
        outcome = nil,      -- last terminal outcome table (uniform engine shape)
        url = nil,
        target_dir = nil,
        confirmed = nil,    -- { url, target_dir, filename } — retry reuses these
        abort_requested = false,
        co = nil,
    }
    return setmetatable(self, { __index = DownloadSession })
end

function DownloadSession:_set_state(new_state, payload)
    self.state = new_state
    if self.on_state then
        self.on_state(new_state, payload or {})
    end
end

--- Spawn a coroutine-driven phase (probe or download). `on_return(self, ...)`
--- receives the coroutine's return values (or an {error=...} table if the body
--- threw). Stepping continues even after CLOSED so the engine can unwind and
--- its terminal funnel can close sockets — the outcome is simply ignored.
function DownloadSession:_spawn(body, on_return)
    local co = coroutine.create(body)
    self.co = co
    local function step()
        if self.co ~= co then return end -- superseded by a newer phase
        local ok, res1, res2, res3 = coroutine.resume(co)
        if not ok then
            self.co = nil
            on_return(self, { __runtime_error = tostring(res1) })
        elseif coroutine.status(co) == "suspended" then
            self.schedule(step)
        else
            self.co = nil
            on_return(self, res1, res2, res3)
        end
    end
    self.schedule(step)
end

function DownloadSession:_abort_fn()
    return function() return self.abort_requested end
end

function DownloadSession:_yield_fn()
    return function() coroutine.yield() end
end

function DownloadSession:_spawn_probe()
    self.abort_requested = false
    self:_spawn(function()
        -- Probe must never throw: unexpected Lua errors soft-degrade to a
        -- fallback name, they do not crash the session.
        local ok, name, final_url, size = pcall(function()
            return self.engine.probeRemoteMetadata(self.url, 4,
                self:_abort_fn(), self:_yield_fn())
        end)
        if not ok then
            return nil, nil, nil
        end
        return name, final_url, size
    end, function(sess, name, final_url, size)
        if sess.state == STATE.CLOSED then return end
        if sess.state == STATE.CANCELING then
            sess:_set_state(STATE.ABORTED)
            return
        end
        -- PROBING (anything else means we were superseded; only CLOSE does that)
        sess:_fire(E.PROBE_RESULT, name, final_url, size)
    end)
end

function DownloadSession:_spawn_download(confirmed)
    self.abort_requested = false
    self.confirmed = confirmed
    local progress_fwd = function(bytes, total, pct, speed)
        if self.state ~= STATE.CLOSED and self.on_progress then
            self.on_progress(bytes, total, pct, speed)
        end
    end
    self:_spawn(function()
        return self.engine.download(confirmed.url, confirmed.target_dir,
            { custom_filename = confirmed.filename, overwrite = false },
            progress_fwd, self:_abort_fn(), self:_yield_fn())
    end, function(sess, outcome)
        if sess.state == STATE.CLOSED then return end
        -- Normalize a runtime error into the uniform failed shape
        if type(outcome) ~= "table" then
            outcome = { kind = "failed", path = nil, meta = {}, error = tostring(outcome) }
        elseif outcome.__runtime_error then
            outcome = { kind = "failed", path = nil, meta = {}, error = outcome.__runtime_error }
        end
        if sess.state == STATE.CANCELING then
            sess.outcome = { kind = KIND_ABORTED, path = nil, meta = {}, error = nil }
            sess:_set_state(STATE.ABORTED)
            return
        end
        sess.outcome = outcome
        if outcome.kind == KIND_COMPLETED then
            sess:_set_state(STATE.COMPLETED, { path = outcome.path, meta = outcome.meta })
        elseif outcome.kind == KIND_ABORTED then
            sess:_set_state(STATE.ABORTED)
        else
            sess:_set_state(STATE.FAILED, { error = outcome.error })
        end
    end)
end

local function begin_attempt(self, url, target_dir)
    self.url = url
    self.target_dir = target_dir
    self.outcome = nil
    self.confirmed = nil
    self.probe_final_url = nil
    pcall(self.engine.sweepOrphanTempFiles, target_dir)

    local url_name = self.engine.extractFilenameFromUrl(url)
    if url_name and url_name ~= "" then
        -- Filename already in the URL path: no probe needed
        self:_set_state(STATE.CONFIRMING, {
            suggested_name = self.engine.sanitizeFilename(url_name),
            size = nil,
            final_url = url,
            target_dir = target_dir,
        })
    else
        self:_set_state(STATE.PROBING, { url = url })
        self:_spawn_probe()
    end
end

-- The transition table: everything legal lives here, everything else is a no-op.
local Handlers = {
    [STATE.IDLE] = {
        [E.START] = function(self, url, target_dir)
            begin_attempt(self, url, target_dir)
        end,
        [E.CLOSE] = function(self)
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.PROBING] = {
        [E.PROBE_RESULT] = function(self, name, final_url, size)
            -- Soft-degrade: a poor probe still reaches CONFIRMING
            self.probe_final_url = final_url or self.url
            self:_set_state(STATE.CONFIRMING, {
                suggested_name = self.engine.sanitizeFilename(name or "download.pdf"),
                size = size,
                final_url = self.probe_final_url,
                target_dir = self.target_dir,
            })
        end,
        [E.CANCEL] = function(self)
            self.abort_requested = true
            self:_set_state(STATE.CANCELING)
        end,
        [E.CLOSE] = function(self)
            self.abort_requested = true
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.CONFIRMING] = {
        [E.CONFIRM_OK] = function(self, raw_name)
            local confirmed = {
                url = self.probe_final_url or self.url,
                target_dir = self.target_dir,
                filename = self.engine.sanitizeFilename(raw_name),
            }
            self:_set_state(STATE.DOWNLOADING, {
                filename = confirmed.filename,
                url = confirmed.url,
                target_dir = confirmed.target_dir,
            })
            self:_spawn_download(confirmed)
        end,
        [E.CANCEL] = function(self)
            self:_set_state(STATE.IDLE)
        end,
        [E.CLOSE] = function(self)
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.DOWNLOADING] = {
        [E.CANCEL] = function(self)
            self.abort_requested = true
            self:_set_state(STATE.CANCELING)
        end,
        [E.CLOSE] = function(self)
            self.abort_requested = true
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.CANCELING] = {
        -- The engine unwinding lands here; whatever it returned, the user
        -- asked to cancel, so the terminal is ABORTED.
        [E.CLOSE] = function(self)
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.COMPLETED] = {
        [E.START] = function(self, url, target_dir)
            begin_attempt(self, url, target_dir)
        end,
        [E.CLOSE] = function(self)
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.FAILED] = {
        [E.RETRY] = function(self)
            -- Retry skips probing: confirmed filename and URL are reused
            self:_set_state(STATE.DOWNLOADING, {
                filename = self.confirmed.filename,
                url = self.confirmed.url,
                target_dir = self.confirmed.target_dir,
            })
            self:_spawn_download(self.confirmed)
        end,
        [E.START] = function(self, url, target_dir)
            begin_attempt(self, url, target_dir)
        end,
        [E.CLOSE] = function(self)
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.ABORTED] = {
        [E.START] = function(self, url, target_dir)
            begin_attempt(self, url, target_dir)
        end,
        [E.CLOSE] = function(self)
            self:_set_state(STATE.CLOSED)
        end,
    },
    [STATE.CLOSED] = {
        -- Terminal and inert: every event is a no-op.
    },
}

function DownloadSession:_fire(event, ...)
    local handler = Handlers[self.state] and Handlers[self.state][event]
    if handler then
        handler(self, ...)
        return true
    end
    return false
end

--- Begin a download attempt. Legal from IDLE and the non-CLOSED terminals;
--- a no-op while a session is active (the double-tap guard).
function DownloadSession:start(url, target_dir)
    return self:_fire(E.START, url, target_dir)
end

--- The single CANCEL path. From PROBING/DOWNLOADING it enters CANCELING and the
--- engine unwinds within one poll interval; from CONFIRMING it returns to IDLE.
function DownloadSession:cancel()
    return self:_fire(E.CANCEL)
end

--- Accept the Pre-Download Confirmation. Legal only from CONFIRMING.
function DownloadSession:confirm(raw_name)
    return self:_fire(E.CONFIRM_OK, raw_name)
end

--- Re-run the confirmed download. Legal only from FAILED (download-phase).
function DownloadSession:retry()
    return self:_fire(E.RETRY)
end

--- Dialog teardown. Aborts any running engine work, marks the session CLOSED,
--- and returns immediately; the engine may still be unwinding and its late
--- terminal outcome is ignored. The engine's funnel closes sockets and removes
--- the partial temp file either way.
function DownloadSession:handleClose()
    return self:_fire(E.CLOSE)
end

return DownloadSession
