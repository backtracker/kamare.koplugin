local Store = require("kamarecachestore")
local Queue = require("kamarecachequeue")

local function fake_settings()
    local s = { data = {} }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value) self.data[key] = value end
    function s:flush() end
    return s
end

local function fake_scheduler()
    local s = { tasks = {}, delays = {} }
    function s:scheduleIn(delay, fn)
        self.tasks[#self.tasks + 1] = { delay = delay, fn = fn }
        self.delays[#self.delays + 1] = delay
    end
    function s:pump(limit)
        local guard = 0
        while #self.tasks > 0 and guard < (limit or 2000) do
            local task = table.remove(self.tasks, 1)
            task.fn()
            guard = guard + 1
        end
        return guard
    end
    return s
end

local function fake_client(opts)
    opts = opts or {}
    local c = { dims_calls = 0, cover_calls = 0 }
    function c:getChapterById(id)
        return {
            pages = opts.pages or 3,
            volumeId = 10, seriesId = 20, libraryId = 30,
            pagesRead = opts.pagesRead or 0,
            files = opts.files or { { bytes = 1000, koreaderHash = "HASH", filePath = "x.cbz" } },
        }
    end
    function c:getFileDimensions(id)
        self.dims_calls = self.dims_calls + 1
        local dims = {}
        for i = 1, (opts.pages or 3) do
            dims[i] = { fileName = string.format("%04d.jpg", i), width = 100, height = 150 }
        end
        return dims
    end
    function c:buildChapterDownloadRequest(id)
        return { url = "http://fixture/chapter/" .. tostring(id), headers = {} }
    end
    function c:buildImageRequestTable(id, page0)
        return { url = "http://fixture/image/" .. tostring(page0) }
    end
    function c:getSeriesCover(id)
        self.cover_calls = self.cover_calls + 1
        return "COVER"
    end
    return c
end

local function fake_archive(opts)
    opts = opts or {}
    local a = { download_calls = 0, extract_calls = 0, part_sizes = {} }
    local fail_remaining = opts.fail_times or 0
    local park_remaining = opts.park_times or 0
    function a.download_to_part(o, cb)
        a.download_calls = a.download_calls + 1
        a.part_sizes[#a.part_sizes + 1] = o.store:file_size(o.part_path)
        if fail_remaining > 0 then
            fail_remaining = fail_remaining - 1
            cb(false, opts.fail_err or "http 500")
            return { cancel = function() a.cancelled = true end }
        end
        if opts.range_unsupported_times and opts.range_unsupported_times > 0 then
            opts.range_unsupported_times = opts.range_unsupported_times - 1
            local f = io.open(o.part_path, "wb")
            f:write(string.rep("x", 100))
            f:close()
            cb(false, "range-unsupported")
            return { cancel = function() a.cancelled = true end }
        end
        local f = io.open(o.part_path, "wb")
        f:write(string.rep("x", o.archive_bytes or 1000))
        f:close()
        if park_remaining > 0 then
            park_remaining = park_remaining - 1
            return { cancel = function() a.cancelled = true end }
        end
        if opts.park then
            return { cancel = function() a.cancelled = true end }
        end
        cb(true, nil, { bytes = o.archive_bytes })
        return { cancel = function() a.cancelled = true end }
    end
    function a.validate_magic() return opts.magic ~= false end
    function a.page_extension() return "jpg" end
    function a.clear_dir(path)
        os.execute("rm -rf '" .. path .. "'")
        return true
    end
    function a.extract_chapter(o)
        a.extract_calls = a.extract_calls + 1
        if opts.extract_err then return nil, opts.extract_err end
        local plan = {}
        local bytes = 0
        os.execute("mkdir -p '" .. o.dest_dir .. "'")
        for i = 1, (o.expected_pages or 3) do
            local dest = string.format("%s/%04d.jpg", o.dest_dir, i)
            local f = assert(io.open(dest, "wb"))
            f:write(string.rep("p", 20))
            f:close()
            plan[#plan + 1] = { path = "src/" .. i .. ".jpg", page = i, dest_name = string.format("%04d.jpg", i) }
            bytes = bytes + 20
        end
        return { pages = o.expected_pages or 3, pagesBytes = bytes, plan = plan }
    end
    return a
end

local function fake_fetch(body)
    local f = { calls = 0, paths = {} }
    function f.page_requests_inflight() return 0 end
    function f.fetch(req, opts, cb)
        f.calls = f.calls + 1
        f.paths[#f.paths + 1] = opts.sink_path
        local dir = opts.sink_path:match("^(.*)/[^/]+$")
        os.execute("mkdir -p '" .. dir .. "'")
        local fh = assert(io.open(opts.sink_path, "wb"))
        fh:write(body or ("\255\216" .. string.rep("i", 8)))
        fh:close()
        cb(nil, 200, { bytes = 10 })
        return { cancel = function() end }
    end
    return f
end

local function make(t, overrides)
    overrides = overrides or {}
    local store = Store:new{ data_dir = t.tmpdir() }
    local free = overrides.free or (10 * 1024 * 1024 * 1024)
    store.free_bytes = function() return free end
    local settings = fake_settings()
    if overrides.settings then
        for k, v in pairs(overrides.settings) do settings.data[k] = v end
    end
    local scheduler = fake_scheduler()
    local ui = { prevent = 0, allow = 0 }
    function ui.prevent_standby() ui.prevent = ui.prevent + 1 end
    function ui.allow_standby() ui.allow = ui.allow + 1 end
    function ui.on_state_change() end
    function ui.on_chapter_done() end

    local q = Queue:new{
        store = store,
        settings = settings,
        client = overrides.client or fake_client(overrides.client_opts),
        scheduler = scheduler,
        network = overrides.network or { isOnline = function() return true end, isWifiOn = function() return true end },
        ui = ui,
        archive = overrides.archive or fake_archive(overrides.archive_opts),
        fetch = overrides.fetch or fake_fetch(),
        clock = function() return 1000 end,
    }
    return q, store, settings, scheduler, ui
end

local function entry(overrides)
    local e = {
        serverKey = "srv1", serverUrl = "https://x", seriesId = 20, seriesName = "Series",
        volumeId = 10, volumeName = "1", chapterId = 100, chapterTitle = "Ch1",
        chapterNumber = "1", order = 1, pages = 3, archiveBytes = 1000,
        archiveExt = "cbz", koreaderHash = "HASH",
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

return function(t)
    -- enqueue rejects when the 2.05x peak does not fit
    do
        local q = make(t, { free = 1 * 1024 * 1024 })
        local ok, err = q:enqueue({ entry() })
        t.is_nil(ok, "reject when not enough space")
        t.ok(err and err:find("space", 1, true) ~= nil, "space error message")
        t.eq(#q.entries, 0, "nothing queued after rejection")
    end

    -- optional absolute cache limit rejects before enqueueing
    do
        local q = make(t, { settings = { cache_limit_mb = 1 } })
        q.store.total_usage = function() return { used = 1024 * 1024, chapters = 1 } end
        local ok, err = q:enqueue({ entry() })
        t.is_nil(ok, "cache limit blocks enqueue")
        t.ok(err and err:find("limit", 1, true) ~= nil, "limit error message")
        t.eq(#q.entries, 0, "nothing queued over limit")
    end

    -- enqueue confirmation can cancel
    do
        local q = make(t)
        local seen
        local ok = q:enqueue({ entry() }, { confirm = function(plan)
            seen = plan
            return false
        end })
        t.is_nil(ok, "confirm false cancels")
        t.eq(seen and seen.chapters, 1, "confirm gets chapter count")
        t.eq(#q.entries, 0, "cancel leaves queue empty")
    end

    -- happy path: download -> extract -> meta/index/series, standby paired
    do
        local arch = fake_archive()
        local q, store, settings, scheduler, ui = make(t, { archive = arch, client_opts = { pagesRead = 2 } })
        local ok = q:enqueue({ entry() }, { confirm = function() return true end })
        t.ok(ok, "enqueue succeeds")
        scheduler:pump()
        local meta = store:read_meta("srv1", 20, 100)
        t.ok(meta ~= nil, "meta written after download")
        t.eq(meta and meta.source, "archive", "meta source archive")
        t.eq(meta and meta.pages, 3, "meta pages")
        t.eq(meta and meta.pagesReadSnapshot, 2, "meta freezes server progress")
        t.eq(meta and meta.dims[2][2], 150, "meta dims")
        t.eq(meta and meta.pageExts[1], "jpg", "meta page extension")
        t.eq(meta and meta.fingerprint, "3:1000:HASH", "meta fingerprint")
        t.eq(#store:read_index("srv1"), 1, "index entry written")
        t.eq(store:read_index("srv1")[1].pagesReadSnapshot, 2, "index keeps the frozen snapshot")
        t.ok(not store:exists(store:part_path("srv1", 100)), "part deleted")
        t.eq(#q.entries, 0, "queue drained")
        t.eq(q.state, "idle", "queue idle")
        t.eq(ui.prevent, ui.allow, "standby calls paired")
        local series = store:read_series("srv1", 20)
        t.ok(series and #series.chapters == 1, "series.json written")
        t.eq(#(store:read_cover("srv1", 20) or ""), 5, "cover cached")
        t.eq(arch.download_calls, 1, "one download call")
        t.eq(#settings:readSetting("download_queue"), 0, "persisted queue empty")
    end

    -- retry with 2s/8s backoff, then success
    do
        local arch = fake_archive({ fail_times = 2 })
        local q, store, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry() })
        scheduler:pump()
        t.eq(arch.download_calls, 3, "three attempts")
        t.ok(store:has_meta("srv1", 20, 100), "meta after retries")
        local saw2, saw8 = false, false
        for _, d in ipairs(scheduler.delays) do
            if d == 2 then saw2 = true end
            if d == 8 then saw8 = true end
        end
        t.ok(saw2 and saw8, "backoff 2s then 8s")
    end

    -- range-unsupported truncates the part and restarts from zero
    do
        local arch = fake_archive({ range_unsupported_times = 1 })
        local q, store, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry() })
        scheduler:pump()
        t.eq(arch.download_calls, 2, "retried after range fallback")
        t.eq(arch.part_sizes[1], 0, "first attempt starts from zero")
        t.eq(arch.part_sizes[2], 0, "restart from zero after truncation")
        t.ok(store:has_meta("srv1", 20, 100), "meta after range restart")
    end

    -- three consecutive chapter failures pause the batch
    do
        local arch = fake_archive({ fail_times = 100 })
        local q, store, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry({ chapterId = 1 }), entry({ chapterId = 2 }), entry({ chapterId = 3 }) })
        scheduler:pump()
        t.eq(arch.download_calls, 9, "each of 3 chapters tried 3 times")
        t.ok(q:is_paused(), "batch paused")
        t.eq(q.pause_reason, "network", "paused for network")
        t.eq(#q.entries, 3, "failed entries kept for retry")
        for _, e in ipairs(q.entries) do
            t.eq(e.state, "failed", "chapter " .. e.chapterId .. " marked failed")
        end
        t.eq(store:has_meta("srv1", 20, 1), false, "no meta for failed chapter")
    end

    -- low space at dequeue pauses instead of failing
    do
        local free = { 10 * 1024 * 1024 * 1024 }
        local q, _, _, scheduler = make(t)
        q.store.free_bytes = function() return free[1] end
        q:enqueue({ entry() })
        free[1] = 100 * 1024 * 1024
        scheduler:pump()
        t.ok(q:is_paused(), "paused on low space")
        t.eq(q.pause_reason, "low_space", "low space reason")
        t.eq(q.entries[1].attempts, 0, "low space is not a chapter failure")
    end

    -- offline and wifi-only pauses
    do
        local q = make(t, { network = { isOnline = function() return false end, isWifiOn = function() return true end } })
        q:enqueue({ entry() })
        q.scheduler:pump()
        t.eq(q.pause_reason, "offline", "offline pause")

        local q2 = make(t, { network = { isOnline = function() return true end, isWifiOn = function() return false end } })
        q2:enqueue({ entry() })
        q2.scheduler:pump()
        t.eq(q2.pause_reason, "wifi", "wifi-only pause")

        local q3 = make(t, {
            network = { isOnline = function() return true end, isWifiOn = function() return false end },
            settings = { download_wifi_only = false },
        })
        q3:enqueue({ entry() })
        q3.scheduler:pump()
        t.ok(q3.entries[1] == nil, "wifi-only off allows download")
    end

    -- cancel keeps the part; abort deletes it
    do
        local arch = fake_archive({ park = true })
        local q, store, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry() })
        scheduler:pump()
        local part = store:part_path("srv1", 100)
        t.ok(store:file_size(part) > 0, "part exists while parked")
        q:cancel("srv1", 100)
        t.eq(#q.entries, 0, "cancel removes entry")
        t.ok(store:file_size(part) > 0, "cancel keeps part")

        local q2, store2, _, scheduler2 = make(t, { archive = fake_archive({ park = true }) })
        q2:enqueue({ entry() })
        scheduler2:pump()
        q2:abort("srv1", 100)
        t.eq(#q2.entries, 0, "abort removes entry")
        t.eq(store2:file_size(store2:part_path("srv1", 100)), 0, "abort deletes part")
    end

    -- live progress: byte callbacks update entry.bytesDone and the UI status
    do
        local statuses = {}
        local arch = fake_archive()
        local base_download = arch.download_to_part
        function arch.download_to_part(o, cb)
            if o.on_progress then
                o.on_progress(400)
                o.on_progress(800)
            end
            return base_download(o, cb)
        end
        local q = make(t, { archive = arch })
        q.ui.on_state_change = function(status) statuses[#statuses + 1] = status end
        q:enqueue({ entry() })
        q.scheduler:pump()
        local saw = false
        for __, s in ipairs(statuses) do
            if s.state == "downloading" and (s.current_bytes_done or 0) > 0 then saw = true end
        end
        t.ok(saw, "progress callbacks report downloaded bytes")
        t.ok(statuses[#statuses] and statuses[#statuses].state == "idle", "idle status last")
    end

    -- entry_progress reads the .part size, which is also the resume offset
    do
        local q, store = make(t)
        local e = entry({ chapterId = 555 })
        store:ensure_dir(store:incoming_dir("srv1"))
        local f = assert(io.open(store:part_path("srv1", 555), "wb"))
        f:write(string.rep("x", 250))
        f:close()
        local done, total, fraction = q:entry_progress(e)
        t.eq(done, 250, "part size is live progress")
        t.eq(total, 1000, "entry total is archiveBytes")
        t.ok(math.abs(fraction - 0.25) < 0.001, "entry fraction")
        local st = q:status()
        t.eq(st.current_bytes_done, 0, "no current entry before start")
    end

    -- per-page downloads report page bytes as progress too
    do
        local statuses = {}
        local q = make(t, { archive = fake_archive({ magic = false }) })
        q.ui.on_state_change = function(status) statuses[#statuses + 1] = status end
        q:enqueue({ entry() })
        q.scheduler:pump()
        local saw = false
        for __, s in ipairs(statuses) do
            if (s.current_bytes_done or 0) >= 10 then saw = true end
        end
        t.ok(saw, "per-page downloads report page bytes")
    end

    -- batch percent is byte based
    do
        local q = make(t)
        q:enqueue({ entry() })
        q.entries[1].bytesDone = 500
        local st = q:status()
        t.ok(math.abs(st.percent - 0.5) < 0.001, "status percent by bytes")
    end

    -- duplicate enqueue is a no-op (single queue, unique chapters)
    do
        local q = make(t)
        t.ok(q:enqueue({ entry() }), "first enqueue ok")
        local ok, err = q:enqueue({ entry() })
        t.is_nil(ok, "duplicate enqueue rejected")
        t.ok(err and err:lower():find("already", 1, true) ~= nil, "duplicate message")
        t.eq(#q.entries, 1, "only one queue entry")
    end

    -- a 200 response that is not an image is rejected (failure injection G2)
    do
        local q, store, _, scheduler = make(t, {
            fetch = fake_fetch("<html>error</html>"),
            archive_opts = { magic = false },
        })
        q:enqueue({ entry() })
        scheduler:pump()
        t.is_nil(store:read_meta("srv1", 20, 100), "no meta for non-image pages")
        t.eq(q.entries[1].state, "failed", "non-image page marks chapter failed")
    end

    -- persistence restores paused, never auto-starts
    do
        local q, _, settings = make(t)
        q:enqueue({ entry() })
        local q2 = Queue:new{
            store = q.store, settings = settings, client = q.client,
            scheduler = fake_scheduler(), archive = q.archive, fetch = q.fetch,
            clock = function() return 2000 end,
        }
        q2:load()
        t.eq(#q2.entries, 1, "queue restored")
        t.ok(q2:is_paused(), "restored queue paused")
        t.eq(q2.entries[1].attempts, 0, "attempts restored")
    end

    -- per-page fallback when the archive is not a zip
    do
        local arch = fake_archive({ magic = false })
        local q, store, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry() })
        scheduler:pump()
        local meta = store:read_meta("srv1", 20, 100)
        t.eq(meta and meta.source, "per-page", "per-page meta after bad magic")
        t.eq(meta and meta.pages, 3, "per-page meta pages")
        t.eq(q.fetch.calls, 3, "one image request per page")
        for i = 1, 3 do
            t.ok(store:file_size(store:page_path("srv1", 20, 100, i, "jpg")) > 0, "page file " .. i)
        end
    end

    -- page-order failure also falls back to per-page, and is remembered so a
    -- retry does not download the archive again
    do
        local arch = fake_archive({ extract_err = "page order mismatch against file-dimensions" })
        local q, store, settings, scheduler = make(t, { archive = arch })
        q:enqueue({ entry() })
        scheduler:pump()
        local meta = store:read_meta("srv1", 20, 100)
        t.eq(meta and meta.source, "per-page", "per-page meta after page-order failure")
        t.eq(q.fetch.calls, 3, "page requests after fallback")
        t.ok(settings.data.archive_order_mismatch
            and settings.data.archive_order_mismatch["srv1:100"],
            "page-order verdict remembered")
    end

    -- a remembered page-order mismatch skips the archive on retry
    do
        local q, _, settings = make(t)
        local e = entry()
        t.ok(not q:_order_flagged(e), "chapter not flagged initially")
        q:_set_order_flag(e, true)
        t.ok(q:_order_flagged(e), "chapter flagged after a mismatch")
        local needs = q:_needs_per_page(e)
        t.ok(needs, "flagged chapter goes straight to per-page")
        q:_set_order_flag(e, false)
        t.ok(not q:_order_flagged(e), "flag cleared after success")
        t.ok(not q:_needs_per_page(e), "archive path allowed again")
        t.ok(settings.data.archive_order_mismatch ~= nil, "flag table persisted")
    end

    -- multi-file chapters go straight to per-page
    do
        local arch = fake_archive()
        local q, store, _, scheduler = make(t, {
            archive = arch,
            client = fake_client({ files = { { bytes = 500 }, { bytes = 500 } } }),
        })
        q:enqueue({ entry() })
        scheduler:pump()
        local meta = store:read_meta("srv1", 20, 100)
        t.eq(meta and meta.source, "per-page", "multi-file uses per-page")
        t.eq(arch.download_calls, 0, "no archive download for multi-file")
        t.eq(q.fetch.calls, 3, "per-page pages fetched")
    end

    -- deleting the entry being downloaded schedules the next one, so the queue
    -- cannot be stranded in "downloading" with no current (07 A4).
    do
        local q, store, _, scheduler = make(t, { archive = fake_archive({ park_times = 1 }) })
        q:enqueue({ entry({ chapterId = 100 }), entry({ chapterId = 101 }) })
        scheduler:pump()
        t.eq(q.current and q.current.chapterId, 100, "first chapter is current")
        t.eq(q.state, "downloading", "queue downloads before the delete")
        t.ok(q:abort("srv1", 100), "abort of the current entry succeeds")
        t.eq(q.state, "queued", "cancelling the current entry requeues the pump")
        t.eq(#q.entries, 1, "only the next entry is left")
        scheduler:pump()
        t.ok(store:has_meta("srv1", 20, 101), "the next chapter downloads")
        t.eq(q.state, "idle", "queue goes idle when drained")
        t.is_nil(q.current, "no current entry after draining")
    end

    -- deleting the only entry goes idle immediately
    do
        local q, _, _, scheduler = make(t, { archive = fake_archive({ park_times = 1 }) })
        q:enqueue({ entry() })
        scheduler:pump()
        t.eq(q.state, "downloading", "single chapter downloading")
        q:abort("srv1", 100)
        t.eq(q.state, "idle", "deleting the last entry goes idle")
        t.is_nil(q.current, "no current after deleting the only entry")
        t.eq(#q.entries, 0, "queue empty after deleting the only entry")
    end

    -- pause then resume continues the batch
    do
        local q, store, _, scheduler = make(t, { archive = fake_archive({ park_times = 1 }) })
        q:enqueue({ entry() })
        scheduler:pump()
        q:pause("user")
        t.eq(q.pause_reason, "user", "manual pause reason")
        t.eq(q.state, "paused", "manual pause state")
        t.eq(q.entries[1].state, "queued", "paused chapter returns to queued")
        q:resume()
        t.ok(not q:is_paused(), "resume clears the pause")
        scheduler:pump()
        t.ok(store:has_meta("srv1", 20, 100), "resume finishes the paused chapter")
    end

    -- a restored queue stays paused until the user resumes it
    do
        local q, _, settings = make(t)
        q:enqueue({ entry() })
        local q2 = Queue:new{
            store = q.store, settings = settings, client = q.client,
            scheduler = fake_scheduler(), archive = q.archive, fetch = q.fetch,
            clock = function() return 2000 end,
        }
        q2:load()
        t.ok(q2:is_paused(), "restored queue is paused")
        t.eq(q2.pause_reason, "restored", "restored pause reason")
        t.eq(q2.state, "paused", "restored state is paused")
        q2:resume()
        t.ok(not q2:is_paused(), "manual resume clears the restored pause")
        q2.scheduler:pump()
        t.eq(#q2.entries, 0, "manual resume continues the restored queue")
    end

    -- network pause: retry revives a failed entry, resets the failure counter
    -- and resumes the batch
    do
        local arch = fake_archive({ fail_times = 100 })
        local q, _, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry({ chapterId = 1 }), entry({ chapterId = 2 }), entry({ chapterId = 3 }) })
        scheduler:pump()
        t.ok(q:is_paused(), "batch paused after consecutive failures")
        t.eq(q.pause_reason, "network", "network pause reason")
        t.eq(#q.entries, 3, "failed entries kept for retry")
        t.ok(q:retry("srv1", 1), "retry of a failed entry")
        t.eq(q.consecutive_failures, 0, "retry resets consecutive failures")
        t.ok(not q:is_paused(), "retry resumes the batch")
        t.eq(q.entries[1].state, "queued", "retried entry is queued again")
    end

    -- low space: resuming must not revive the download
    do
        local free = { 10 * 1024 * 1024 * 1024 }
        local q, _, _, scheduler = make(t)
        q.store.free_bytes = function() return free[1] end
        q:enqueue({ entry() })
        free[1] = 100 * 1024 * 1024
        scheduler:pump()
        t.eq(q.pause_reason, "low_space", "paused on low space")
        q:resume()
        scheduler:pump()
        t.ok(q:is_paused(), "resume does not revive a low-space pause")
        t.eq(q.pause_reason, "low_space", "still low space after resume")
        t.eq(q.entries[1].attempts, 0, "the chapter was never attempted")
    end
end
