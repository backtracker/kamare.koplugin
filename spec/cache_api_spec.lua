local Cache = require("kamarecache")
local Store = require("kamarecachestore")
local Journal = require("kamarejournal")

local function fake_settings()
    local s = { data = { servers = {
        { name = "S", kavita_url = "https://example", key = "k1" },
    } } }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value) self.data[key] = value end
    function s:flush() end
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
    local m = {
        serverKey = "k1", serverUrl = "https://example", libraryId = 10,
        seriesId = 20, seriesName = "Series", volumeId = 30, volumeName = "1",
        chapterId = chapter_id, chapterTitle = "Ch" .. chapter_id, chapterNumber = "1",
        order = chapter_id, pages = 100, source = "archive",
        archiveBytes = 5000, pagesBytes = 5200, koreaderHash = "H",
        fingerprint = "100:5000:H", state = "complete",
    }
    for k, v in pairs(extra or {}) do m[k] = v end
    assert(store:write_meta(m))
    assert(store:upsert_index_entry("k1", {
        seriesId = 20, seriesName = "Series", chapterId = chapter_id,
        chapterTitle = m.chapterTitle, order = chapter_id, pages = 100,
        archiveBytes = 5000, pagesBytes = 5200, stale = extra and extra.stale or false,
        cachedAt = 1,
    }))
end

return function(t)
    t.eq(Cache.api_version, 1, "api version")
    for _, cap in ipairs({ "status", "enqueue", "delete", "summary" }) do
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

    t.is_nil(Cache.status("https://unknown", 1), "unknown server has no status")
    t.is_nil(Cache.status("https://example", 12345), "uncached chapter has no status")

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
end
