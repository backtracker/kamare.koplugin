local Journal = require("kamarejournal")

local function fake_scheduler()
    local s = { tasks = {}, delays = {}, unscheduled = 0 }
    function s:scheduleIn(delay, fn)
        self.tasks[#self.tasks + 1] = { delay = delay, fn = fn }
        self.delays[#self.delays + 1] = delay
    end
    function s:unschedule(fn)
        for i, t in ipairs(self.tasks) do
            if t.fn == fn then
                table.remove(self.tasks, i)
                self.unscheduled = self.unscheduled + 1
                return
            end
        end
    end
    function s:pump()
        while #self.tasks > 0 do
            local t = table.remove(self.tasks, 1)
            t.fn()
        end
    end
    return s
end

local function fake_client(opts)
    opts = opts or {}
    local c = { remote = opts.remote or {}, posts = {}, order = {} }
    function c:getReaderProgress(chapter_id)
        if opts.fetch_fail then return nil, -1 end
        return { pageNum = self.remote[chapter_id] or 0 }, 200
    end
    function c:postReaderProgress(payload)
        if opts.post_fail then return -1 end
        self.posts[#self.posts + 1] = payload
        self.order[#self.order + 1] = payload.chapterId
        return 200
    end
    return c
end

local function entry(chapter_id, overrides)
    local e = {
        serverKey = "srv1", libraryId = 30, seriesId = 20, volumeId = 10,
        chapterId = chapter_id or 100, seriesName = "Series", chapterTitle = "Ch",
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

local function make(t, opts)
    opts = opts or {}
    local sched = fake_scheduler()
    local clock = { value = opts.clock or 1000000 }
    local j = Journal:new{
        settings_dir = t.tmpdir(),
        scheduler = sched,
        clock = function() return clock.value end,
        limits = opts.limits,
    }
    j:load()
    return j, sched, clock
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

return function(t)
    -- position lifecycle
    do
        local j, sched = make(t)
        local pos = j:set_position(entry(100), 60)
        t.ok(pos ~= nil, "set_position returns entry")
        t.eq(pos.pageNum, 60, "position page")
        t.eq(pos.status, "pending", "position pending")
        t.eq(j:pending_count(), 1, "one pending")
        j:set_position(entry(100), 61)
        t.eq(j:get_position("srv1", 100).pageNum, 61, "position updated")
        j:mark_pushed("srv1", 100)
        t.eq(j:get_position("srv1", 100).status, "pushed", "marked pushed")
        t.eq(j:pending_count(), 0, "no pending after push")
        j:force_flush()
        t.ok(exists(j:path()), "journal file written")
    end

    -- 20s idle debounce: repeat updates cancel the previous timer
    do
        local j, sched = make(t)
        j:set_position(entry(100), 10)
        t.eq(#sched.tasks, 1, "flush scheduled")
        t.eq(sched.delays[1], 20, "flush delay 20s")
        j:set_position(entry(100), 11)
        t.eq(#sched.tasks, 1, "still one timer")
        t.ok(sched.unscheduled >= 1, "previous timer cancelled")
        sched:pump()
        t.ok(exists(j:path()), "debounced flush wrote file")
    end

    -- 20 page advances force an immediate flush
    do
        local j, sched = make(t)
        for p = 1, 20 do j:set_position(entry(100), p) end
        t.ok(exists(j:path()), "forced flush after 20 pages")
        t.eq(#sched.tasks, 0, "no pending timer after forced flush")
    end

    -- reload + corrupt recovery
    do
        local j = make(t)
        j:set_position(entry(100), 42)
        j:touch_session(entry(100), 40, 42, { startTs = 1000, endTs = 1300 })
        j:force_flush()
        local j2 = Journal:new{ settings_dir = j:_settings_dir(), clock = function() return 1300 end }
        j2:load()
        t.eq(j2:get_position("srv1", 100).pageNum, 42, "position survives reload")
        t.eq(#j2:get_sessions(), 1, "session survives reload")
        t.eq(j2:session_seconds(), 300, "session seconds")

        local f = assert(io.open(j:path(), "wb"))
        f:write("{broken")
        f:close()
        local j3 = Journal:new{ settings_dir = j:_settings_dir(), clock = function() return 7 end }
        j3:load()
        t.eq(#j3:all_positions(), 0, "corrupt journal starts empty")
        t.ok(exists(j:path() .. ".corrupt.7"), "corrupt journal renamed")
    end

    -- eviction limits
    do
        local j = make(t, { limits = { positions = 3, sessions = 3 }, clock = 2000000 })
        for i = 1, 5 do
            j:set_position(entry(i), 1)
            j:mark_pushed("srv1", i)
        end
        j:set_position(entry(99), 5)
        j:evict()
        t.eq(j:pending_count(), 1, "pending survives eviction")
        local n = 0
        for _ in pairs(j.positions) do n = n + 1 end
        t.eq(n, 3, "positions capped at 3 (pending protected)")
        t.ok(j:get_position("srv1", 99) ~= nil, "pending position kept")

        -- pushed older than 7 days are dropped
        local j2 = make(t, { clock = 1000000 })
        j2:set_position(entry(1), 1)
        j2:mark_pushed("srv1", 1)
        j2.clock = function() return 1000000 + 8 * 24 * 3600 end
        j2:evict()
        t.is_nil(j2:get_position("srv1", 1), "old pushed position evicted")

        -- sessions: 90 days and cap
        local j3 = make(t, { limits = { sessions = 3 }, clock = 10000000 })
        for i = 1, 5 do
            j3:touch_session(entry(200 + i), 1, 2, { startTs = 10000000 - i, endTs = 10000000 - i + 1 })
        end
        j3:touch_session(entry(300), 1, 2, { startTs = 1, endTs = 2 })
        j3:evict()
        t.eq(#j3:get_sessions(), 3, "sessions capped")
        for _, s in ipairs(j3:get_sessions()) do
            t.ok(s.endTs and s.endTs > 1000000, "old session dropped")
        end
    end

    -- monotonic sync rules
    do
        local function journal_with_local(page)
            local j = make(t)
            j:set_position(entry(100), page, { source = "offline" })
            return j
        end

        local j1 = journal_with_local(30)
        local c1 = fake_client({ remote = { [100] = 60 } })
        local s1 = j1:sync(c1)
        t.eq(s1.superseded, 1, "local behind -> superseded")
        t.eq(s1.pushed, 0, "local behind does not push")
        t.eq(#c1.posts, 0, "no POST when behind")
        t.eq(j1:get_position("srv1", 100).status, "superseded", "status superseded")

        local j2 = journal_with_local(60)
        local c2 = fake_client({ remote = { [100] = 30 } })
        local s2 = j2:sync(c2)
        t.eq(s2.pushed, 1, "local ahead pushes")
        t.eq(#c2.posts, 1, "one POST")
        t.eq(c2.posts[1].pageNum, 60, "exact PageNum replayed")
        t.eq(c2.posts[1].chapterId, 100, "chapter id")
        t.eq(j2:get_position("srv1", 100).status, "pushed", "status pushed")

        local j3 = journal_with_local(50)
        local c3 = fake_client({ remote = { [100] = 50 } })
        local s3 = j3:sync(c3)
        t.eq(s3.superseded, 1, "equal -> superseded")
        t.eq(#c3.posts, 0, "equal does not push")

        local j4 = journal_with_local(70)
        local c4 = fake_client({ fetch_fail = true })
        local s4 = j4:sync(c4)
        t.eq(s4.skipped, 1, "fetch failure skips")
        t.eq(#c4.posts, 0, "no blind push when fetch fails")
        t.eq(j4:get_position("srv1", 100).status, "pending", "status kept pending")

        local j5 = journal_with_local(20)
        local c5 = fake_client({ remote = { [100] = 60 } })
        local s5 = j5:sync(c5, {
            is_current = function() return true end,
            prompt_current = function() return "local" end,
        })
        t.eq(s5.conflict, 1, "current book conflict detected")
        t.eq(#c5.posts, 1, "user choice overrides monotonic")
        t.eq(c5.posts[1].pageNum, 20, "pushed local page after choice")

        local j6 = journal_with_local(20)
        local c6 = fake_client({ remote = { [100] = 60 } })
        local s6 = j6:sync(c6, {
            is_current = function() return true end,
            prompt_current = function() return "remote" end,
        })
        t.eq(s6.superseded, 1, "keep remote -> superseded")
        t.eq(#c6.posts, 0, "keep remote does not push")
    end

    -- sync order follows session end time
    do
        local j = make(t)
        j:set_position(entry(1), 10, { source = "offline" })
        j:set_position(entry(2), 10, { source = "offline" })
        j:touch_session(entry(1), 1, 10, { startTs = 100, endTs = 200 })
        j:touch_session(entry(2), 1, 10, { startTs = 100, endTs = 300 })
        local c = fake_client({ remote = {} })
        j:sync(c)
        t.eq(c.order[1], 1, "earlier session pushed first")
        t.eq(c.order[2], 2, "later session pushed second")
    end

    -- offline sessions: start/update/end, online sessions ignored
    do
        local j, _, clock = make(t)
        j:session_start(entry(100), 5, { source = "offline" })
        clock.value = clock.value + 60
        j:session_update(entry(100), 8)
        clock.value = clock.value + 120
        j:session_end(entry(100))
        t.eq(#j:get_sessions(), 1, "offline session recorded")
        t.eq(j:get_sessions()[1].startPage, 5, "session start page")
        t.eq(j:get_sessions()[1].endPage, 8, "session end page")
        t.eq(j:session_seconds(), 180, "session duration")

        j:session_start(entry(101), 1, { source = "online" })
        j:session_end(entry(101))
        t.eq(#j:get_sessions(), 1, "online session not recorded")
    end
end
