local Store = require("kamarecachestore")

local function fake_settings(servers)
    local s = {
        data = { servers = servers or {} },
    }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value)
        self.data[key] = value
    end
    function s:flush()
        self.flushed = (self.flushed or 0) + 1
    end
    return s
end

local function make_store(t)
    return Store:new{ data_dir = t.tmpdir() }
end

local function write_page(store, sk, sid, cid, page, bytes, ext)
    local path = store:page_path(sk, sid, cid, page, ext or "jpg")
    assert(store:ensure_dir(path:match("^(.*)/[^/]+$")))
    assert(store:write_file_atomic(path, bytes))
    return path
end

return function(t)
    local store = make_store(t)
    local sk, sid, cid = "a1b2c3d4", 10679, 18847

    -- paths
    t.eq(store:cache_root(), store:_data_dir() .. "/kamare/cache", "cache root")
    t.eq(store:chapter_dir(sk, sid, cid), store:cache_root() .. "/a1b2c3d4/10679/18847", "chapter dir")
    t.eq(store:part_path(sk, cid), store:cache_root() .. "/a1b2c3d4/.incoming/18847.part", "part path")
    t.eq(store:page_path(sk, sid, cid, 7), store:chapter_dir(sk, sid, cid) .. "/0007.jpg", "page path pad")
    t.ok(store:page_path(sk, sid, cid, 12345, "png"):match("%.png$") ~= nil, "page ext kept")
    t.ok(store:page_path(sk, sid, cid, 1, ".webp"):match("%.webp$") ~= nil, "leading dot stripped")

    -- meta roundtrip
    local meta = {
        serverKey = sk, serverUrl = "https://example", libraryId = 10,
        seriesId = sid, seriesName = "Series", volumeId = 16448, volumeName = "1",
        chapterId = cid, chapterTitle = "Chapter 1", chapterNumber = "1", order = 1,
        pages = 3, source = "archive", archiveBytes = 100, archiveExt = "cbz",
        koreaderHash = "DEADBEEF", pagesBytes = 120, dims = { { 100, 150 }, { 100, 150 }, { 100, 150 } },
        pagesReadSnapshot = 1, fingerprint = "3:100:DEADBEEF", state = "complete",
    }
    t.ok(store:write_meta(meta), "write meta")
    t.ok(store:has_meta(sk, sid, cid), "has meta")
    local got = store:read_meta(sk, sid, cid)
    t.eq(got and got.chapterId, cid, "read meta id")
    t.eq(got and got.dims[2][2], 150, "read meta dims")
    t.ok(not store:exists(store:meta_path(sk, sid, cid) .. ".tmp"), "no tmp left")

    -- corrupt json is nil, not an error
    assert(store:write_file_atomic(store:meta_path(sk, sid, cid), "{not json"))
    t.is_nil(store:read_meta(sk, sid, cid), "corrupt meta -> nil")

    -- rewrite meta for index/usage tests
    assert(store:write_meta(meta))
    write_page(store, sk, sid, cid, 1, string.rep("a", 100))
    write_page(store, sk, sid, cid, 2, string.rep("b", 200))
    write_page(store, sk, sid, cid, 3, string.rep("c", 300))
    assert(store:ensure_dir(store:series_dir(sk, sid)))
    assert(store:write_cover(sk, sid, string.rep("x", 50), "jpg"))

    -- series
    t.ok(store:write_series(sk, {
        seriesId = sid, seriesName = "Series", libraryId = 10, coverFile = "cover.jpg",
        chapters = { { id = cid, volumeId = 16448, number = "1", order = 1, title = "Chapter 1", pages = 3, bytes = 100 } },
    }), "write series")
    local series = store:read_series(sk, sid)
    t.eq(series and #series.chapters, 1, "read series")
    t.eq(#store:read_cover(sk, sid), 50, "read cover")

    -- index rebuild + entries
    os.remove(store:index_path(sk))
    local entries = store:load_index_or_rebuild(sk)
    t.eq(#entries, 1, "rebuild finds chapter")
    t.eq(entries[1].chapterId, cid, "index chapter id")
    t.eq(entries[1].pagesBytes, 120, "index pagesBytes")
    t.eq(entries[1].stale, false, "index stale default")

    -- stale survives rebuild
    t.ok(store:set_stale(sk, sid, cid, true), "set stale")
    t.ok(store:is_stale(sk, sid, cid), "is stale")
    local rebuilt = store:rebuild_index(sk)
    t.eq(rebuilt[1].stale, true, "stale preserved across rebuild")

    -- bulk stale update
    t.ok(store:update_stale(sk, { [cid] = false }), "bulk stale clear")
    t.ok(not store:is_stale(sk, sid, cid), "bulk stale cleared")
    t.ok(store:update_stale(sk, { [cid] = true }), "bulk stale update")
    t.ok(store:is_stale(sk, sid, cid), "bulk stale applied")

    -- index is written atomically + sorted deterministically
    assert(store:write_index(sk, {
        { chapterId = 2, seriesName = "B", order = 1 },
        { chapterId = 1, seriesName = "A", order = 2 },
        { chapterId = 3, seriesName = "A", order = 1 },
    }))
    local sorted = store:read_index(sk)
    t.eq(sorted[1].chapterId, 3, "sorted A/1")
    t.eq(sorted[2].chapterId, 1, "sorted A/2")
    t.eq(sorted[3].chapterId, 2, "sorted B/1")

    -- upsert / remove
    assert(store:write_index(sk, {}))
    t.ok(store:upsert_index_entry(sk, { seriesId = sid, chapterId = cid, seriesName = "Series" }), "upsert")
    t.eq(#store:read_index(sk), 1, "upsert added")
    store:remove_index_chapter(sk, sid, cid)
    t.eq(#store:read_index(sk), 0, "index entry removed")

    -- usage: 3 pages (600) + cover 50 + part 40
    local part = store:part_path(sk, cid)
    assert(store:ensure_dir(store:incoming_dir(sk)))
    assert(store:write_file_atomic(part, string.rep("p", 40)))
    local expected_usage = store:dir_usage(store:chapter_dir(sk, sid, cid))
        + store:file_size(store:cover_path(sk, sid)) + 40
    local usage = store:server_usage(sk)
    t.eq(usage.used, expected_usage, "server usage includes pages+meta+cover+part")
    t.eq(usage.chapters, 1, "server usage chapters")

    local total = store:total_usage()
    t.eq(total.used, expected_usage, "total usage")
    t.ok(type(store:free_bytes()) == "number", "free bytes is a number")

    -- free space is measured on the data dir before the cache root exists
    do
        local dir = t.tmpdir()
        local fresh = Store:new{ data_dir = dir }
        t.ok(not fresh:exists(fresh:cache_root()), "cache root absent before first download")
        local free = fresh:free_bytes()
        t.ok(type(free) == "number" and free > 0, "free space falls back to data dir")
    end

    -- delete chapter clears dir + part + index
    local freed = store:delete_chapter(sk, sid, cid)
    t.eq(freed, expected_usage - 50, "delete chapter frees pages+meta+part (cover kept)")
    t.ok(not store:exists(store:chapter_dir(sk, sid, cid)), "chapter dir gone")
    t.ok(not store:exists(part), "part gone")
    t.eq(#store:read_index(sk), 0, "index entry gone")
    t.ok(store:exists(store:series_dir(sk, sid)), "series metadata kept")

    -- series/server/all deletion counts
    assert(store:write_meta(meta))
    write_page(store, sk, sid, cid, 1, string.rep("a", 10))
    local before_series = store:server_usage(sk).used
    local freed2, n2 = store:delete_series(sk, sid)
    t.eq(n2, 1, "delete series chapter count")
    t.eq(freed2, before_series, "delete series frees pages+meta+cover")
    t.ok(not store:exists(store:series_dir(sk, sid)), "series dir gone")

    assert(store:write_meta(meta))
    write_page(store, sk, sid, cid, 1, string.rep("a", 10))
    local freed3, n3 = store:delete_server(sk)
    t.eq(n3, 1, "delete server chapter count")
    t.ok(freed3 >= 10, "delete server frees pages")
    t.ok(not store:exists(store:server_root(sk)), "server dir gone")

    assert(store:write_meta(meta))
    write_page(store, sk, sid, cid, 1, string.rep("a", 10))
    local freed4, n4 = store:delete_all()
    t.eq(n4, 1, "delete all chapter count")
    t.ok(freed4 >= 10, "delete all frees pages")
    t.eq(#store:list_server_keys(), 0, "no servers left")

    -- server key resolution
    local settings = fake_settings({
        { name = "Old", kavita_url = "https://old", key = "deadbeef" },
        { name = "Legacy", kavita_url = "https://legacy" },
    })
    t.eq(store:resolve_server_key(settings, { base_url = "https://old" }), "deadbeef", "reuse by url")
    t.eq(store:resolve_server_key(settings, { name = "Old" }), "deadbeef", "reuse by name")
    local generated = store:resolve_server_key(settings, { base_url = "https://legacy" })
    t.ok(generated and #generated == 8 and generated:match("^[0-9a-f]+$"), "legacy key generated")
    t.eq(settings.data.servers[2].key, generated, "legacy key persisted")
    t.ok((settings.flushed or 0) >= 1, "server key change flushed immediately")
    t.eq(store:resolve_server_key(settings, { base_url = "https://legacy" }), generated, "key stable")
    t.is_nil(store:resolve_server_key(settings, { base_url = "https://unknown" }), "unknown server nil")
end
