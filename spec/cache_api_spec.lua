local Cache = require("kamarecache")
local Store = require("kamarecachestore")
local Journal = require("kamarejournal")
local Queue = require("kamarecachequeue")

local function fake_settings(servers)
    local s = {
        data = { servers = servers or {
            { name = "S", kavita_url = "https://example", key = "k1", api_key = "old" },
        } },
        flushed = 0,
        saved = 0,
    }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value)
        self.data[key] = value
        self.saved = self.saved + 1
    end
    function s:flush()
        self.flushed = self.flushed + 1
        return true
    end
    return s
end

local function fake_queue()
    local q = { aborted = {}, enqueued = nil }
    function q:contains(server_key, chapter_id) return chapter_id == 99 end
    function q:abort(server_key, chapter_id)
        self.aborted[#self.aborted + 1] = chapter_id
        return true
    end
    function q:enqueue(entries, opts)
        self.enqueued = entries
        self.opts = opts
        return true
    end
    return q
end

local function meta(store, chapter_id, extra)
    extra = extra or {}
    local series_id = extra.seriesId or 20
    local series_name = extra.seriesName or "Series"
    local m = {
        serverKey = extra.serverKey or "k1", serverUrl = "https://example", libraryId = 10,
        seriesId = series_id, seriesName = series_name, volumeId = 30, volumeName = "1",
        chapterId = chapter_id, chapterTitle = "Ch" .. chapter_id, chapterNumber = "1",
        order = chapter_id, pages = extra.pages or 100, source = "archive",
        archiveBytes = extra.archiveBytes or 5000, pagesBytes = extra.pagesBytes or 5200,
        koreaderHash = "H", fingerprint = "100:5000:H", state = "complete",
    }
    if extra.pagesReadSnapshot then m.pagesReadSnapshot = extra.pagesReadSnapshot end
    assert(store:write_meta(m))
    assert(store:upsert_index_entry(m.serverKey, {
        seriesId = series_id, seriesName = series_name, chapterId = chapter_id,
        chapterTitle = m.chapterTitle, order = chapter_id, pages = m.pages,
        archiveBytes = m.archiveBytes, pagesBytes = m.pagesBytes,
        stale = extra.stale and true or false,
        cachedAt = 1,
    }))
    return m
end

local function server_entry(settings, url)
    for __, s in ipairs(settings.data.servers or {}) do
        if s.kavita_url == url or s.url == url then return s end
    end
end

local function fake_scheduler()
    local s = { tasks = {} }
    function s:scheduleIn(delay, fn) s.tasks[#s.tasks + 1] = fn end
    function s:pump(limit)
        local n = 0
        while #s.tasks > 0 and n < (limit or 500) do
            local task = table.remove(s.tasks, 1)
            task()
            n = n + 1
        end
        return n
    end
    return s
end

local function fake_archive(opts)
    opts = opts or {}
    local calls = 0
    return {
        download_to_part = function(o, cb)
            calls = calls + 1
            local f = assert(io.open(o.part_path, "wb"))
            f:write(string.rep("x", o.archive_bytes or 1000))
            f:close()
            if opts.park_first and calls == 1 then
                return { cancel = function() end }
            end
            cb(true)
            return { cancel = function() end }
        end,
        validate_magic = function() return true end,
        page_extension = function() return "jpg" end,
        clear_dir = function() end,
        extract_chapter = function(o)
            os.execute("mkdir -p '" .. o.dest_dir .. "'")
            local plan = {}
            for i = 1, (o.expected_pages or 3) do
                local path = string.format("%s/%04d.jpg", o.dest_dir, i)
                local f = assert(io.open(path, "wb"))
                f:write("p")
                f:close()
                plan[#plan + 1] = { path = "src/" .. i .. ".jpg", page = i }
            end
            return { pages = o.expected_pages or 3, pagesBytes = 3, plan = plan }
        end,
    }
end

-- A real Queue with injected scheduler/archive/client so queue changes are
-- exercised through the facade without any network, sleep or user data dir.
local function real_queue(store, settings, opts)
    opts = opts or {}
    local client = { hydrate_calls = 0, chapters = opts.chapters or {} }
    function client:getChapterById(id)
        self.hydrate_calls = self.hydrate_calls + 1
        return self.chapters[id]
    end
    function client:getFileDimensions()
        local dims = {}
        for i = 1, 3 do
            dims[i] = { fileName = string.format("%04d.jpg", i), width = 100, height = 150 }
        end
        return dims
    end
    function client:buildChapterDownloadRequest(id)
        return { url = "http://fixture/chapter/" .. tostring(id), headers = {} }
    end
    function client:getSeriesCover() return "COVER" end
    local scheduler = fake_scheduler()
    local queue = Queue:new{
        store = store,
        settings = settings,
        client = client,
        scheduler = scheduler,
        network = {
            isOnline = function() return true end,
            isWifiOn = function() return true end,
        },
        ui = {},
        archive = fake_archive(opts.archive_opts),
        fetch = { page_requests_inflight = function() return 0 end },
        clock = function() return 1000 end,
    }
    return queue, scheduler, client
end

return function(t)
    Cache.set_context(nil)

    t.eq(Cache.api_version, 1, "api version")
    for __, cap in ipairs({ "status", "summary", "enqueue", "delete", "server", "resume",
        "queue", "queue_control", "index", "open", "estimate" }) do
        t.ok(Cache.capabilities[cap], "capability " .. cap)
    end

    local dir = t.tmpdir()
    local store = Store:new{ data_dir = dir }
    local settings = fake_settings()
    local journal = Journal:new{ settings_dir = dir }
    journal:load()
    local queue = fake_queue()
    Cache.set_context{
        store = store, settings = settings, journal = journal, queue = queue,
        client = {},
    }

    -- set_context merges; the reset seam clears it (spec 08 A4).
    t.ok(Cache.get_context().store == store, "set_context keeps injected instances")
    Cache.set_context{ settings = fake_settings() }
    t.ok(Cache.get_context().store == store, "set_context merges instead of replacing")
    t.ok(Cache.get_context().journal == journal, "set_context keeps the journal")
    Cache.set_context{ settings = settings }

    t.is_nil(Cache.status("https://unknown", 1), "unknown server has no status")
    t.is_nil(Cache.status("https://example", 12345), "uncached chapter has no status")
    -- status/summary are identity-tier only: no journal, no queue.
    Cache.set_context(nil)
    local identity_dir = t.tmpdir()
    local identity_store = Store:new{ data_dir = identity_dir }
    local identity_settings = fake_settings()
    Cache.set_context{
        store = identity_store, settings = identity_settings, client = {},
    }
    Cache.status("https://example", 1)
    Cache.summary("https://example")
    t.is_nil(Cache.get_context().journal, "status/summary build no journal")
    t.is_nil(Cache.get_context().queue, "status/summary build no queue")

    -- register_server: validation, normalization, key preservation, idempotence.
    local reg_dir = t.tmpdir()
    local reg_store = Store:new{ data_dir = reg_dir }
    local reg_settings = fake_settings({})
    local reg_client = { bearer = "stale" }
    Cache.set_context{
        store = reg_store, settings = reg_settings, client = reg_client,
    }
    local ok0, code0 = Cache.register_server{ api_key = "k" }
    t.is_nil(ok0, "register_server needs a base url")
    t.eq(code0, "base_url_required", "missing base_url code")
    local ok1, code1 = Cache.register_server{ base_url = "https://a" }
    t.is_nil(ok1, "register_server needs an api key")
    t.eq(code1, "api_key_required", "missing api_key code")

    local key, rerr = Cache.register_server{
        base_url = "  https://Example.com/kavita/  ", api_key = "secret",
    }
    t.ok(key, "register_server returns a server key " .. tostring(rerr))
    local added = server_entry(reg_settings, "https://Example.com/kavita")
    t.ok(added ~= nil, "url is trimmed, trailing slash dropped, path prefix kept")
    t.eq(added and added.key, key, "new server carries the returned key")
    t.eq(added and added.api_key, "secret", "api key stored")
    t.eq(added and added.url, "https://Example.com/kavita", "url mirror kept")
    t.eq(added and added.name, "Example.com", "name defaults to the host")
    t.eq(reg_client.base_url, "https://Example.com/kavita", "client base_url mirrored")
    t.eq(reg_client.api_key, "secret", "client api_key mirrored")
    t.eq(reg_client.auth_method, "apiKey", "client uses api key auth")
    t.is_nil(reg_client.bearer, "bearer token cleared")
    t.is_nil(Cache.get_context().queue, "register_server builds no queue")
    t.is_nil(Cache.get_context().journal, "register_server builds no journal")
    t.ok(not reg_store:exists(reg_store:cache_root()), "register_server creates no cache dir")
    local flushes, saves = reg_settings.flushed, reg_settings.saved

    local again = Cache.register_server{
        base_url = "https://Example.com/kavita", api_key = "secret",
    }
    t.eq(again, key, "register_server is idempotent")
    t.eq(reg_settings.flushed, flushes, "unchanged values do not flush")
    t.eq(reg_settings.saved, saves, "unchanged values do not save")
    t.eq(#reg_settings.data.servers, 1, "idempotent call adds no server")

    local rotated = Cache.register_server{
        base_url = "https://Example.com/kavita/", api_key = "rotated",
    }
    t.eq(rotated, key, "an api key rotation keeps the server key")
    t.eq(server_entry(reg_settings, "https://Example.com/kavita").api_key, "rotated",
        "api key updated in place")
    t.eq(#reg_settings.data.servers, 1, "api key rotation adds no server")
    t.eq(reg_settings.flushed, flushes + 1, "a real change flushes once")

    -- A server entry whose key was wiped by Kamare's editor gets one back.
    local legacy_settings = fake_settings({
        { name = "Legacy", kavita_url = "https://legacy", version = 5 },
    })
    Cache.set_context{
        store = Store:new{ data_dir = t.tmpdir() },
        settings = legacy_settings,
        client = {},
    }
    local legacy_key = Cache.register_server{ base_url = "https://legacy", api_key = "l" }
    local legacy = server_entry(legacy_settings, "https://legacy")
    t.ok(legacy_key, "a key is generated for an existing keyless server")
    t.eq(legacy and legacy.key, legacy_key, "generated key is stored")
    t.eq(legacy and legacy.name, "Legacy", "match by url preserves the name")
    t.eq(legacy and legacy.version, 5, "unrelated server fields are preserved")

    -- Matching falls back to the name when the URL changed.
    local by_name_settings = fake_settings({
        { name = "Home", kavita_url = "https://old", key = "home1" },
    })
    Cache.set_context{
        store = Store:new{ data_dir = t.tmpdir() },
        settings = by_name_settings,
        client = {},
    }
    local home_key = Cache.register_server{
        name = "Home", base_url = "https://new/kavita", api_key = "n",
    }
    t.eq(home_key, "home1", "match by name preserves the server key")
    t.eq(server_entry(by_name_settings, "https://new/kavita") ~= nil, true,
        "url updated in place on a name match")
    t.eq(#by_name_settings.data.servers, 1, "name match adds no server")

    -- A failed flush is reported, not swallowed.
    local failing = fake_settings()
    function failing:flush() self.flushed = self.flushed + 1; return false end
    Cache.set_context{
        store = Store:new{ data_dir = t.tmpdir() }, settings = failing, client = {},
    }
    local fok, fcode = Cache.register_server{
        base_url = "https://example", api_key = "changed",
    }
    t.is_nil(fok, "flush failure is reported")
    t.eq(fcode, "settings_write_failed", "flush failure code")

    -- resume_page: journal > snapshot > nil, read-only.
    local resume_dir = t.tmpdir()
    local resume_store = Store:new{ data_dir = resume_dir }
    local resume_settings = fake_settings()
    local resume_journal = Journal:new{ settings_dir = resume_dir, clock = function() return 5000 end }
    resume_journal:load()
    Cache.set_context{
        store = resume_store, settings = resume_settings, journal = resume_journal,
        client = {},
    }
    meta(resume_store, 10)
    meta(resume_store, 11, { pagesReadSnapshot = 42 })
    meta(resume_store, 12, { pagesReadSnapshot = 150 })
    meta(resume_store, 13)

    local unknown, ucode = Cache.resume_page("https://nope", 10)
    t.is_nil(unknown, "unknown server has no resume page")
    t.eq(ucode, "unknown_server", "resume_page reports unknown_server")
    t.eq(#resume_settings.data.servers, 1, "resume_page creates no server key")

    local plain = Cache.resume_page("https://example", 10)
    t.eq(plain and plain.page, 1, "no progress starts at page 1")
    t.is_nil(plain and plain.source, "no progress has no source")
    t.is_nil(plain and plain.status, "no progress has no status")

    local snapshot = Cache.resume_page("https://example", 11)
    t.eq(snapshot and snapshot.page, 42, "snapshot is a 1-based page number")
    t.eq(snapshot and snapshot.source, "snapshot", "snapshot source")
    t.is_nil(snapshot and snapshot.updated_at, "snapshot has no timestamp")

    local clamped_snapshot = Cache.resume_page("https://example", 12)
    t.eq(clamped_snapshot and clamped_snapshot.page, 100, "snapshot is clamped to pages")

    resume_journal:set_position({
        serverKey = "k1", chapterId = 13, seriesId = 20, volumeId = 30, libraryId = 10,
        seriesName = "Series", chapterTitle = "Ch13",
    }, 60, { source = "offline", force = true })
    local position_count = #resume_journal:all_positions()
    local flushes_before = resume_settings.flushed
    local from_journal = Cache.resume_page("https://example", 13)
    t.eq(from_journal and from_journal.page, 60, "journal wins over the snapshot")
    t.eq(from_journal and from_journal.source, "journal", "journal source")
    t.eq(from_journal and from_journal.status, "pending", "journal status is passed through")
    t.eq(from_journal and from_journal.updated_at, 5000, "journal timestamp is passed through")
    t.eq(#resume_journal:all_positions(), position_count, "resume_page never writes the journal")
    t.eq(resume_settings.flushed, flushes_before, "resume_page never flushes settings")
    t.eq(#resume_settings.data.servers, 1, "resume_page never creates a server key")

    resume_journal:set_position({
        serverKey = "k1", chapterId = 13, seriesId = 20, volumeId = 30, libraryId = 10,
        seriesName = "Series", chapterTitle = "Ch13",
    }, 500, { source = "offline", force = true })
    t.eq((Cache.resume_page("https://example", 13) or {}).page, 100, "journal page is clamped")

    resume_journal:mark_pushed("k1", 13)
    t.eq((Cache.resume_page("https://example", 13) or {}).status, "pushed",
        "pushed status is passed through")
    -- A series id skips the index lookup but returns the same answer.
    t.eq((Cache.resume_page("https://example", 13, 20) or {}).page, 100,
        "explicit series id resolves the same chapter")

    -- Back to the main fixture for the remaining contract groups.
    Cache.set_context{
        store = store, settings = settings, journal = journal, queue = queue,
        client = {},
    }

    meta(store, 1)
    local s1 = Cache.status("https://example", 1)
    t.eq(s1 and s1.state, "complete", "complete status")
    t.eq(s1 and s1.bytes, 5200, "status bytes")
    t.eq(s1 and s1.total, 5000, "status total")

    meta(store, 2, { stale = true })
    local s2 = Cache.status("https://example", 2)
    t.eq(s2 and s2.state, "stale", "stale status")

    -- partial download (no meta, .part present)
    assert(store:ensure_dir(store:incoming_dir("k1")))
    assert(store:write_file_atomic(store:part_path("k1", 77), string.rep("x", 123)))
    local s3 = Cache.status("https://example", 77)
    t.eq(s3 and s3.state, "partial", "partial status")
    t.eq(s3 and s3.bytes, 123, "partial bytes")

    local summary = Cache.summary("https://example")
    t.eq(summary.chapters, 2, "summary chapters")
    t.ok(summary.used >= 123, "summary counts on-disk usage (part + metadata)")
    t.ok(type(summary.available) == "number", "summary available")

    -- enqueue maps caller fields (snake_case and camelCase) onto queue entries
    local ok = Cache.enqueue("https://example", {
        { chapter_id = 5, series_id = 20, volume_id = 30, pages = 10, bytes = 1000,
          title = "Five", order = 5 },
        { chapterId = 6, seriesId = 20, volumeId = 30, pages = 10, bytes = 1000,
          chapterTitle = "Six", order = 6 },
        { no_id = true },
    })
    t.ok(ok, "enqueue accepted")
    t.eq(#queue.enqueued, 2, "invalid entries dropped")
    t.eq(queue.enqueued[1].serverKey, "k1", "serverKey resolved")
    t.eq(queue.enqueued[1].chapterId, 5, "snake_case chapter id")
    t.eq(queue.enqueued[1].chapterTitle, "Five", "snake_case title")
    t.eq(queue.enqueued[2].chapterId, 6, "camelCase chapter id")

    -- queue_state: entries and bytes are scoped to the requested server.
    local function queue_stub(entries, opts)
        opts = opts or {}
        local q = {
            entries = entries or {},
            state = opts.state or "idle",
            pause_reason = opts.pause_reason,
            current = opts.current,
            paused = false,
            calls = {},
            PEAK_FACTOR = 2.05,
            LOW_WATER_BYTES = 500 * 1024 * 1024,
        }
        function q:entry_progress(e)
            local total = e.archiveBytes or 0
            local done = e.bytesDone or 0
            return done, total, total > 0 and done / total or 0
        end
        function q:contains(server_key, chapter_id) return false end
        function q:abort(server_key, chapter_id)
            self.calls[#self.calls + 1] = { "abort", server_key, chapter_id }
            return true
        end
        function q:pause(reason)
            self.calls[#self.calls + 1] = { "pause", reason }
            self.paused = true
            self.state = "paused"
            self.pause_reason = reason
        end
        function q:resume()
            self.calls[#self.calls + 1] = { "resume" }
            self.paused = false
            self.pause_reason = nil
            self.state = #self.entries > 0 and "downloading" or "idle"
        end
        function q:retry(server_key, chapter_id)
            self.calls[#self.calls + 1] = { "retry", server_key, chapter_id }
            self.consecutive_failures = 0
            return true
        end
        return q
    end

    local q100 = { serverKey = "k1", chapterId = 100, seriesId = 20, state = "downloading",
        archiveBytes = 1000, bytesDone = 250, attempts = 1 }
    local q900 = { serverKey = "k9", chapterId = 900, seriesId = 90, state = "queued",
        archiveBytes = 5000 }
    local q101 = { serverKey = "k1", chapterId = 101, seriesId = 20, state = "failed",
        archiveBytes = 2000, attempts = 3, lastError = "http 500" }
    local states_queue = queue_stub({ q100, q900, q101 }, {
        state = "downloading", current = q100,
    })
    Cache.set_context{ queue = states_queue }
    local qs = Cache.queue_state("https://example")
    t.ok(qs ~= nil, "queue_state returns a table")
    t.eq(qs and qs.state, "downloading", "queue_state reports the global state")
    t.eq(qs and qs.bytes_done, 250, "queue_state sums this server's done bytes")
    t.eq(qs and qs.bytes_total, 3000, "queue_state sums this server's total bytes")
    t.ok(qs and math.abs(qs.percent - (250 / 3000)) < 0.0001, "queue_state percent is scoped")
    t.eq(qs and qs.pending_count, 2, "queue_state counts this server's entries")
    t.eq(qs and qs.current_chapter_id, 100, "queue_state current chapter belongs to the server")
    t.is_nil(qs and qs.entries[900], "queue_state hides another server's entry")
    t.eq(qs and qs.entries[100].bytes_done, 250, "entry progress comes from entry_progress")
    t.eq(qs and qs.entries[100].bytes_total, 1000, "entry total is archiveBytes")
    t.eq(qs and qs.entries[101].attempts, 3, "entry attempts passed through")
    t.eq(qs and qs.entries[101].last_error, "http 500", "entry last error passed through")
    t.eq(qs and qs.last_error, "http 500", "queue error comes from this server's failures")
    t.eq(#states_queue.calls, 0, "queue_state never touches the queue")

    states_queue.current = q900
    states_queue.pause_reason = "network"
    local qs2 = Cache.queue_state("https://example")
    t.is_nil(qs2 and qs2.current_chapter_id, "another server's current chapter is hidden")
    t.eq(qs2 and qs2.pause_reason, "network", "pause reason passed through")

    Cache.set_context{ queue = queue_stub({}, { state = "idle" }) }
    local qs3 = Cache.queue_state("https://example")
    t.eq(qs3 and qs3.state, "idle", "empty queue is idle")
    t.eq(qs3 and qs3.pending_count, 0, "empty queue has no pending entries")
    t.eq(qs3 and next(qs3.entries), nil, "empty queue has no entries")
    t.eq(qs3 and qs3.percent, 0, "empty queue percent")

    local qunknown, qucode = Cache.queue_state("https://nope")
    t.is_nil(qunknown, "unknown server has no queue state")
    t.eq(qucode, "unknown_server", "queue_state unknown_server code")

    -- queue control: pause/resume act on the shared queue, retry is filtered.
    local paused_queue = queue_stub({ q100 }, { state = "downloading", current = q100 })
    Cache.set_context{ queue = paused_queue }
    t.ok(Cache.queue_pause("https://example"), "queue_pause returns true")
    t.eq(#paused_queue.calls, 1, "queue_pause calls the queue once")
    t.eq(paused_queue.calls[1][1], "pause", "queue_pause calls pause")
    t.eq(paused_queue.calls[1][2], "user", "queue_pause reason is user")
    t.ok(Cache.queue_resume("https://example"), "queue_resume returns true")
    t.eq(paused_queue.calls[2][1], "resume", "queue_resume calls resume")
    t.eq(paused_queue.state, "downloading", "resume restarts the queue")

    local empty_queue = queue_stub({}, { state = "idle" })
    Cache.set_context{ queue = empty_queue }
    t.ok(Cache.queue_pause("https://example"), "pausing an empty queue is a no-op")
    t.eq(#empty_queue.calls, 0, "empty queue is not paused")
    t.eq(empty_queue.state, "idle", "empty queue stays idle")

    local retry_queue = queue_stub({
        { serverKey = "k1", chapterId = 100, state = "queued" },
        { serverKey = "k1", chapterId = 101, state = "failed" },
        { serverKey = "k1", chapterId = 102, state = "downloading" },
        { serverKey = "k1", chapterId = 103, state = "complete" },
        { serverKey = "k9", chapterId = 200, state = "queued" },
    })
    retry_queue.consecutive_failures = 3
    Cache.set_context{ queue = retry_queue }
    t.ok(Cache.queue_retry("https://example", { 100, "101", 102, 103, 200 }),
        "queue_retry revives retryable entries")
    t.eq(#retry_queue.calls, 2, "only queued/failed entries of this server are retried")
    t.eq(retry_queue.calls[1][1], "retry", "queue_retry calls retry")
    t.eq(retry_queue.calls[1][2], "k1", "retry uses the resolved server key")
    t.eq(retry_queue.calls[1][3], 100, "retry accepts a numeric chapter id")
    t.eq(retry_queue.calls[2][3], 101, "retry accepts a string chapter id")
    t.eq(retry_queue.consecutive_failures, 0, "queue_retry resets consecutive failures")
    local rok, rcode = Cache.queue_retry("https://example", { 102, 103 })
    t.is_nil(rok, "nothing retryable is an error")
    t.eq(rcode, "retry_no_entry", "retry_no_entry code")
    t.eq(#retry_queue.calls, 2, "no retry call for non-retryable entries")

    -- index: a shelf projection grouped by series.
    local idx_dir = t.tmpdir()
    local idx_store = Store:new{ data_dir = idx_dir }
    local idx_settings = fake_settings()
    local idx_journal = Journal:new{ settings_dir = idx_dir, clock = function() return 7000 end }
    idx_journal:load()
    Cache.set_context(nil)
    Cache.set_context{
        store = idx_store, settings = idx_settings, journal = idx_journal, client = {},
    }
    meta(idx_store, 10, { seriesId = 20, seriesName = "Alpha" })
    meta(idx_store, 11, { seriesId = 20, seriesName = "Alpha" })
    meta(idx_store, 12, { seriesId = 21, seriesName = "Beta", stale = true })
    assert(idx_store:write_cover("k1", 20, "COVER", "jpg"))
    idx_journal:set_position({ serverKey = "k1", chapterId = 10, seriesId = 20,
        volumeId = 30, libraryId = 10, seriesName = "Alpha", chapterTitle = "Ch10" },
        5, { source = "offline", force = true })
    idx_journal.clock = function() return 8000 end
    idx_journal:set_position({ serverKey = "k1", chapterId = 12, seriesId = 21,
        volumeId = 30, libraryId = 10, seriesName = "Beta", chapterTitle = "Ch12" },
        2, { source = "offline", force = true })

    local idx = Cache.index("https://example")
    t.ok(idx ~= nil, "index returns a projection")
    local alpha = idx and idx.series["20"]
    t.ok(alpha ~= nil, "index groups by series")
    t.eq(alpha and alpha.seriesId, 20, "index series id")
    t.eq(alpha and alpha.seriesName, "Alpha", "index series name")
    t.eq(alpha and alpha.chapters, 2, "index chapter count")
    t.eq(alpha and alpha.complete, true, "index complete flag")
    t.eq(alpha and alpha.stale, false, "index stale flag")
    t.eq(alpha and alpha.bytes, 10400, "index bytes are the page bytes")
    t.eq(alpha and alpha.lastReadAt, 7000, "index last read timestamp")
    t.eq(alpha and alpha.coverPath, idx_store:cover_path("k1", 20), "index cover path")
    local beta = idx and idx.series["21"]
    t.eq(beta and beta.complete, false, "stale-only series is not complete")
    t.eq(beta and beta.stale, true, "index marks a stale series")
    t.eq(beta and beta.lastReadAt, 8000, "last read is per series")
    t.is_nil(beta and beta.coverPath, "cover path only when the file exists")
    t.ok(idx and idx.used > 0, "index reports used bytes")
    t.eq(#idx_settings.data.servers, 1, "index creates no server key")
    t.eq(idx_settings.flushed, 0, "index never flushes settings")
    t.eq(#idx_journal:all_positions(), 2, "index never writes the journal")
    t.is_nil(Cache.get_context().queue, "index never builds the queue")

    local idx_unknown, idx_code = Cache.index("https://nope")
    t.is_nil(idx_unknown, "index of an unknown server is nil")
    t.eq(idx_code, "unknown_server", "index unknown_server code")
    t.eq(#idx_settings.data.servers, 1, "index of an unknown server creates no key")

    -- estimate: read-only capacity verdict reusing the queue's hydration and
    -- its 2.05 / 500 MB constants (spec 01 A8 / 07 A6).
    local est_dir = t.tmpdir()
    local est_store = Store:new{ data_dir = est_dir }
    local est_settings = fake_settings()
    local est_journal = Journal:new{ settings_dir = est_dir }
    est_journal:load()
    local est_free = 10 * 1024 * 1024 * 1024
    est_store.free_bytes = function() return est_free end
    local est_queue, _, est_client = real_queue(est_store, est_settings, {
        chapters = {
            [101] = { pages = 3, volumeId = 30, seriesId = 20, libraryId = 10, pagesRead = 0,
                files = { { bytes = 2000, koreaderHash = "H", filePath = "x.cbz" } } },
        },
    })
    Cache.set_context(nil)
    Cache.set_context{
        store = est_store, settings = est_settings, journal = est_journal,
        queue = est_queue, client = est_client,
    }
    local est = Cache.estimate("https://example", {
        { chapterId = 100, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
        { chapter_id = 101, series_id = 20 },
    })
    t.eq(est and est.chapters, 2, "estimate counts downloadable chapters")
    t.eq(est and est.bytes, 6150, "estimate applies the 2.05 peak factor")
    t.eq(est and est.available, est_free, "estimate reports available space")
    t.eq(est and est.ok, true, "estimate is ok when it fits")
    t.is_nil(est and est.reason, "estimate ok has no reason")
    t.eq(est_client.hydrate_calls, 1, "estimate hydrates entries that lack metadata")
    t.eq(#est_queue.entries, 0, "estimate never enqueues")
    t.is_nil(est_store:read_index("k1"), "estimate writes no index")
    t.eq(est_settings.saved, 0, "estimate never saves settings")
    t.eq(est_settings.flushed, 0, "estimate never flushes settings")
    t.eq(#est_settings.data.servers, 1, "estimate creates no server key")

    meta(est_store, 102)
    local nothing = Cache.estimate("https://example", { { chapterId = 102, seriesId = 20 } })
    t.eq(nothing and nothing.reason, "nothing_to_do", "cached chapters make estimate a no-op")
    t.eq(nothing and nothing.ok, false, "nothing to do is not ok")
    t.eq(nothing and nothing.chapters, 0, "nothing to do counts no chapters")

    local failed_hydrate = Cache.estimate("https://example", { { chapterId = 999, seriesId = 20 } })
    t.eq(failed_hydrate and failed_hydrate.reason, "nothing_to_do",
        "failed hydration leaves nothing to do")

    est_free = 100
    local no_space = Cache.estimate("https://example", {
        { chapterId = 103, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
    })
    t.eq(no_space and no_space.reason, "space", "too little space is a space verdict")
    t.eq(no_space and no_space.ok, false, "space verdict is not ok")

    est_free = 100 * 1024 * 1024
    local low_water = Cache.estimate("https://example", {
        { chapterId = 103, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
    })
    t.eq(low_water and low_water.reason, "low_water", "below 500 MB is a low-water verdict")

    est_free = 10 * 1024 * 1024 * 1024
    est_settings.data.cache_limit_mb = 1
    local total_usage = est_store.total_usage
    est_store.total_usage = function() return { used = 1024 * 1024, chapters = 5 } end
    local limited = Cache.estimate("https://example", {
        { chapterId = 103, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
    })
    t.eq(limited and limited.reason, "space", "a cache limit is a space verdict")
    est_store.total_usage = total_usage
    est_settings.data.cache_limit_mb = nil

    local est_unknown, est_code = Cache.estimate("https://nope", {
        { chapterId = 1, seriesId = 20 },
    })
    t.is_nil(est_unknown, "estimate of an unknown server is nil")
    t.eq(est_code, "unknown_server", "estimate unknown_server code")
    t.eq(#est_settings.data.servers, 1, "estimate of an unknown server creates no key")

    -- enqueue space failures carry stable codes and a detail table.
    local sp_dir = t.tmpdir()
    local sp_store = Store:new{ data_dir = sp_dir }
    local sp_settings = fake_settings()
    local sp_free = 1000
    sp_store.free_bytes = function() return sp_free end
    local sp_queue = real_queue(sp_store, sp_settings)
    Cache.set_context(nil)
    Cache.set_context{
        store = sp_store, settings = sp_settings, client = {}, queue = sp_queue,
    }
    local sp_entry = { chapterId = 200, seriesId = 20, volumeId = 30, libraryId = 10,
        pages = 3, archiveBytes = 1000, files = {} }
    local sok, scode, _, sdetail = Cache.enqueue("https://example", { sp_entry })
    t.is_nil(sok, "enqueue rejects when the peak does not fit")
    t.eq(scode, "not_enough_space", "not_enough_space code")
    t.eq(sdetail and sdetail.needed, 2050, "space detail carries the peak need")
    t.eq(sdetail and sdetail.available, sp_free, "space detail carries available bytes")
    t.eq(#sp_queue.entries, 0, "a rejected enqueue adds nothing")

    sp_free = 100 * 1024 * 1024
    local wok, wcode, _, wdetail = Cache.enqueue("https://example", { sp_entry })
    t.is_nil(wok, "enqueue rejects below the low-water mark")
    t.eq(wcode, "low_space", "low_space code")
    t.eq(wdetail and wdetail.available, 100 * 1024 * 1024, "low space detail available")
    t.eq(wdetail and wdetail.low_water, 500 * 1024 * 1024, "low space detail low water")

    sp_settings.data.cache_limit_mb = 1
    local sp_total = sp_store.total_usage
    sp_store.total_usage = function() return { used = 1024 * 1024, chapters = 5 } end
    sp_free = 10 * 1024 * 1024 * 1024
    local lok, lcode, _, ldetail = Cache.enqueue("https://example", { sp_entry })
    t.is_nil(lok, "enqueue rejects over the cache limit")
    t.eq(lcode, "cache_limit_reached", "cache_limit_reached code")
    t.eq(ldetail and ldetail.used, 1024 * 1024, "limit detail used")
    t.eq(ldetail and ldetail.limit, 1024 * 1024, "limit detail limit")
    t.eq(ldetail and ldetail.needed, 2050, "limit detail needed")
    sp_store.total_usage = sp_total
    sp_settings.data.cache_limit_mb = nil

    local ook, _, oinfo = Cache.enqueue("https://example", { sp_entry })
    t.ok(ook, "enqueue succeeds when it fits")
    t.eq(oinfo and oinfo.chapters, 1, "enqueue plan chapter count")
    t.eq(oinfo and oinfo.bytes, 2050, "enqueue plan reports the peak")
    local dqok, dqcode = Cache.enqueue("https://example", { sp_entry })
    t.is_nil(dqok, "a queued chapter is not enqueued twice")
    t.eq(dqcode, "already_queued", "already_queued code")
    meta(sp_store, 201)
    local dcok, dccode = Cache.enqueue("https://example", {
        { chapterId = 201, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
    })
    t.is_nil(dcok, "a cached chapter is not enqueued")
    t.eq(dccode, "already_cached", "already_cached code")

    -- delete of the chapter being downloaded lets the queue continue (07 A4).
    local dl_dir = t.tmpdir()
    local dl_store = Store:new{ data_dir = dl_dir }
    local dl_settings = fake_settings()
    dl_store.free_bytes = function() return 10 * 1024 * 1024 * 1024 end
    local dl_queue, dl_scheduler, dl_client = real_queue(dl_store, dl_settings, {
        archive_opts = { park_first = true },
        chapters = {
            [300] = { pages = 3, volumeId = 30, seriesId = 20, libraryId = 10, pagesRead = 0,
                files = { { bytes = 1000, koreaderHash = "H", filePath = "x.cbz" } } },
            [301] = { pages = 3, volumeId = 30, seriesId = 20, libraryId = 10, pagesRead = 0,
                files = { { bytes = 1000, koreaderHash = "H", filePath = "x.cbz" } } },
        },
    })
    Cache.set_context(nil)
    Cache.set_context{
        store = dl_store, settings = dl_settings, client = dl_client, queue = dl_queue,
    }
    t.ok(Cache.enqueue("https://example", {
        { chapterId = 300, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
        { chapterId = 301, seriesId = 20, volumeId = 30, libraryId = 10, pages = 3,
          archiveBytes = 1000, files = {} },
    }), "two chapters enqueued")
    dl_scheduler:pump()
    t.eq(dl_queue.current and dl_queue.current.chapterId, 300, "first chapter is downloading")
    local dlok, dlerr, dlcount = Cache.delete("https://example", { 300 })
    t.ok(dlok, "deleting the downloading chapter succeeds " .. tostring(dlerr))
    t.eq(dlcount, 1, "the in-flight part counts as deleted")
    t.eq(#dl_queue.entries, 1, "the next entry is still queued")
    dl_scheduler:pump()
    t.ok(dl_store:has_meta("k1", 20, 301), "the next chapter downloads after the cancel")
    t.eq(dl_queue.state, "idle", "queue goes idle after the last chapter")
    t.is_nil(dl_queue.current, "no current entry left")

    Cache.set_context{
        store = store, settings = settings, journal = journal, queue = queue,
        client = {},
    }

    -- delete removes files, aborts the queue entry, never touches the journal
    journal:set_position({ serverKey = "k1", chapterId = 1, seriesId = 20,
        volumeId = 30, libraryId = 10, seriesName = "Series", chapterTitle = "Ch1" },
        60, { source = "offline", force = true })
    local dir1 = store:chapter_dir("k1", 20, 1)
    assert(store:ensure_dir(dir1))
    assert(store:write_file_atomic(dir1 .. "/0001.jpg", "PAGE"))
    local dok, derr, deleted = Cache.delete("https://example", { 1, 99 })
    t.ok(dok, "delete ok " .. tostring(derr))
    t.eq(deleted, 1, "deleted cached chapter count")
    t.eq(#queue.aborted, 1, "queue aborted for chapter 99")
    t.ok(not store:exists(dir1), "chapter dir removed")
    t.eq(journal:pending_count(), 1, "journal untouched by delete")
    t.eq(journal:get_position("k1", 1).pageNum, 60, "journal position kept")

    -- delete refuses as a whole while the chapter is open in the viewer (07 A1).
    meta(store, 8)
    local open_dir = store:chapter_dir("k1", 20, 8)
    assert(store:ensure_dir(open_dir))
    assert(store:write_file_atomic(open_dir .. "/0001.jpg", "PAGE"))
    package.loaded["kamareimageviewer"] = {
        active_instance = { metadata = { chapterId = 8 }, cache_server_key = "k1" },
    }
    local kok, kcode = Cache.delete("https://example", { 8 })
    t.is_nil(kok, "an open chapter cannot be deleted")
    t.eq(kcode, "chapter_open", "chapter_open code")
    t.ok(store:exists(open_dir), "chapter_open deletes no files")
    t.ok(store:has_meta("k1", 20, 8), "chapter_open keeps the meta")
    t.ok(Cache.status("https://example", 8) ~= nil, "chapter_open keeps the index entry")

    package.loaded["kamareimageviewer"].active_instance.cache_server_key = "k2"
    t.ok(Cache.delete("https://example", { 8 }), "another server's viewer does not block deletion")
    t.ok(not store:exists(open_dir), "delete works once the viewer is on another server")

    -- A viewer without a cache key (online stream) still protects by chapter id.
    meta(store, 9)
    package.loaded["kamareimageviewer"] = {
        active_instance = { metadata = { chapterId = 9 } },
    }
    local zok, zcode = Cache.delete("https://example", { 9 })
    t.is_nil(zok, "a viewer without a cache key still protects")
    t.eq(zcode, "chapter_open", "nil cache key still reports chapter_open")
    package.loaded["kamareimageviewer"] = nil

    -- delete must not invent a server key for an unknown URL.
    local flush_before_delete = settings.flushed
    local uok, ucode = Cache.delete("https://nope", { 1 })
    t.is_nil(uok, "delete of an unknown server fails")
    t.eq(ucode, "unknown_server", "delete unknown_server code")
    t.eq(#settings.data.servers, 1, "delete creates no server key")
    t.eq(settings.flushed, flush_before_delete, "delete flushes no settings")

    -- open: parameter validation and degradation (the viewer is not loadable
    -- headless, so only the pre-viewer paths are asserted).
    local open_dir2 = t.tmpdir()
    local open_store = Store:new{ data_dir = open_dir2 }
    local open_settings = fake_settings({})
    local open_client = {}
    Cache.set_context(nil)
    Cache.set_context{
        store = open_store, settings = open_settings, client = open_client,
    }
    package.loaded["kamareimageviewer"] = { active_instance = nil }
    local open_entry = { chapterId = 50, seriesId = 20, volumeId = 30, libraryId = 10, pages = 5 }

    local ob, obcode = Cache.open{ api_key = "k", entry = open_entry }
    t.is_nil(ob, "open needs a base url")
    t.eq(obcode, "base_url_required", "open base_url_required code")
    local okk, okcode = Cache.open{ base_url = "https://example", entry = open_entry }
    t.is_nil(okk, "open needs an api key")
    t.eq(okcode, "api_key_required", "open api_key_required code")

    local nog, nogcode = Cache.open{
        base_url = "https://example", api_key = "k", entry = { chapterId = 50, seriesId = 20 },
    }
    t.is_nil(nog, "open needs pages")
    t.eq(nogcode, "no_pages", "open no_pages code")
    t.is_nil(Cache.get_context().queue, "open never builds the queue")
    t.is_nil(Cache.get_context().journal, "open never builds a journal before it opens")

    open_settings.data.force_offline = true
    local off, offcode = Cache.open{
        base_url = "https://example", api_key = "k", entry = open_entry,
    }
    t.is_nil(off, "open refuses an uncached chapter offline")
    t.eq(offcode, "offline_not_cached", "open offline_not_cached code")
    t.eq(server_entry(open_settings, "https://example") ~= nil, true,
        "open mirrors the server before opening")
    t.eq(open_client.base_url, "https://example", "open mirrors the client base url")
    t.ok(not open_store:exists(open_store:cache_root()), "open creates no cache directory")

    package.loaded["kamareimageviewer"] = {
        active_instance = { metadata = { chapterId = 1 } },
    }
    local run, runcode = Cache.open{
        base_url = "https://example", api_key = "k", entry = open_entry,
    }
    t.is_nil(run, "open refuses a second viewer")
    t.eq(runcode, "viewer_running", "open viewer_running code")
    package.loaded["kamareimageviewer"] = nil

    -- A cached chapter opened at an explicit start page still needs the read
    -- tier: the viewer writes the offline session to the journal on close.
    local sj_dir = t.tmpdir()
    local sj_store = Store:new{ data_dir = sj_dir }
    local sj_settings = fake_settings()
    Cache.set_context(nil)
    Cache.set_context{
        store = sj_store, settings = sj_settings, client = {},
    }
    meta(sj_store, 60, { pages = 5 })
    local captured
    package.loaded["kamareimageviewer"] = {
        active_instance = nil,
        new = function(_, o)
            captured = o
            return { _aborted = false }
        end,
    }
    local viewer = Cache.open{
        base_url = "https://example", api_key = "k",
        entry = { chapterId = 60, seriesId = 20, volumeId = 30, libraryId = 10, pages = 5 },
        start_page = 3,
    }
    t.ok(viewer ~= nil, "open returns a viewer for a cached chapter at a start page")
    t.eq(captured and captured.metadata.startPage, 3, "explicit start page wins")
    t.eq(captured and captured.page_source, "local", "cached chapter reads from disk")
    t.ok(captured and captured.cache_journal ~= nil,
        "cached open carries a journal even with an explicit start page")
    t.eq(captured and captured.cache_journal, Cache.get_context().journal,
        "open builds and passes the read-tier journal")
    -- The viewer's close path writes the physical page through this seam.
    captured.cache_journal:set_position({
        serverKey = captured.cache_server_key,
        libraryId = captured.metadata.libraryId,
        seriesId = captured.metadata.seriesId,
        volumeId = captured.metadata.volumeId,
        chapterId = captured.metadata.chapterId,
        seriesName = captured.metadata.seriesName,
        chapterTitle = captured.metadata.chapterTitle,
    }, 4, { source = "offline", force = true })
    local closed = Cache.resume_page("https://example", 60, 20)
    t.eq(closed and closed.page, 4, "the position written on close is readable")
    t.eq(closed and closed.source, "journal", "close records a journal-sourced position")
    package.loaded["kamareimageviewer"] = nil

    Cache.set_context(nil)
    t.is_nil(Cache.get_context(), "set_context(nil) resets for the next spec")
end
