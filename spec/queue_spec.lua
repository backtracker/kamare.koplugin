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
            pagesRead = 0,
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

local function fake_fetch()
    local f = { calls = 0, paths = {} }
    function f.page_requests_inflight() return 0 end
    function f.fetch(req, opts, cb)
        f.calls = f.calls + 1
        f.paths[#f.paths + 1] = opts.sink_path
        local dir = opts.sink_path:match("^(.*)/[^/]+$")
        os.execute("mkdir -p '" .. dir .. "'")
        local fh = assert(io.open(opts.sink_path, "wb"))
        fh:write(string.rep("i", 10))
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
        fetch = fake_fetch(),
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
        local q, store, settings, scheduler, ui = make(t, { archive = arch })
        local ok = q:enqueue({ entry() }, { confirm = function() return true end })
        t.ok(ok, "enqueue succeeds")
        scheduler:pump()
        local meta = store:read_meta("srv1", 20, 100)
        t.ok(meta ~= nil, "meta written after download")
        t.eq(meta and meta.source, "archive", "meta source archive")
        t.eq(meta and meta.pages, 3, "meta pages")
        t.eq(meta and meta.dims[2][2], 150, "meta dims")
        t.eq(meta and meta.pageExts[1], "jpg", "meta page extension")
        t.eq(meta and meta.fingerprint, "3:1000:HASH", "meta fingerprint")
        t.eq(#store:read_index("srv1"), 1, "index entry written")
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

    -- page-order failure also falls back to per-page
    do
        local arch = fake_archive({ extract_err = "page order mismatch against file-dimensions" })
        local q, store, _, scheduler = make(t, { archive = arch })
        q:enqueue({ entry() })
        scheduler:pump()
        local meta = store:read_meta("srv1", 20, 100)
        t.eq(meta and meta.source, "per-page", "per-page meta after page-order failure")
        t.eq(q.fetch.calls, 3, "page requests after fallback")
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
end
