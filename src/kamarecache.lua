--[[--
Public cache facade for other plugins (Moon is the only intended consumer).

Contract (API_VERSION = 1):
  cache.api_version            -> 1
  cache.capabilities           -> { status, summary, enqueue, delete, server,
                                    resume, queue, queue_control, index, open,
                                    estimate }
  cache.status(base_url, id)   -> nil | { state = "partial"|"complete"|"stale", bytes, total }
  cache.summary(base_url)      -> { used, available, chapters }
  cache.register_server{ name?, base_url, api_key } -> serverKey | nil, code, message
  cache.resume_page(base_url, chapter_id, series_id?) -> { page, source, status, updated_at } | nil
  cache.enqueue(base_url, entries, opts) -> true | nil, code, message
  cache.delete(base_url, chapter_ids)    -> true, nil, deleted | nil, code, message
  cache.queue_state(base_url)            -> state table | nil, code, message
  cache.queue_pause/resume/retry(...)    -> true | nil, code, message
  cache.index(base_url)                  -> shelf projection | nil, code, message
  cache.open{ ... }                      -> viewer | nil, code, message
  cache.estimate(base_url, entries)      -> space estimate | nil, code, message

Calls always take `base_url`; the internal serverKey is resolved here so
callers never depend on Kamare's storage details. Read-only calls never create
a server key and never flush settings (a missing derived index may be rebuilt).
Writes only touch Kamare's own queue and cache directory; the reading journal is
never modified by enqueue/delete.

The context is built lazily in three tiers (identity / read / queue) so a
read-only call never drags in the queue, and `register_server` never creates a
queue or a journal. One store, one journal, one queue per process.

Capability probing (spec 09): `pcall(require, "kamarecache")` + api_version +
capabilities. Missing module or a different major version means "no cache UI",
silently -- never raise at the caller.
--]]

local logger = require("logger")
local _ = require("gettext")
local CacheUtil = require("kamarecacheutil")

local Cache = {}

Cache.api_version = 1
Cache.capabilities = {
    status = true,
    summary = true,
    enqueue = true,
    delete = true,
    server = true,        -- register_server
    resume = true,        -- resume_page
    queue = true,         -- queue_state
    queue_control = true, -- queue_pause / queue_resume / queue_retry
    index = true,         -- index
    open = true,          -- open
    estimate = true,      -- estimate
}

local context

-- Test seam (spec 08 A4): `set_context(nil)` clears every instance. A table
-- argument merges -- existing instances always win, only missing keys are
-- filled (spec 01 A2).
function Cache.set_context(ctx)
    if ctx == nil then
        context = nil
        return true
    end
    context = context or {}
    for key, value in pairs(ctx) do
        if value ~= nil then context[key] = value end
    end
    return true
end

function Cache.get_context()
    return context
end

local function base_context()
    if not context then context = {} end
    return context
end

-- Tier 1: store + settings + client. register_server / status / summary stop
-- here: no journal, no queue.
local function ensure_identity()
    local ctx = base_context()
    if not ctx.store then
        ctx.store = require("kamarecachestore"):new{}
    end
    if not ctx.settings then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        ctx.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kamare.lua")
    end
    if not ctx.client then
        ctx.client = require("kavitaclient")
    end
    return ctx
end

-- Tier 2: identity + journal (read-only). Needed by resume_page and index
-- (journal position), and by open for a cached chapter (the viewer writes it).
local function ensure_read()
    local ctx = ensure_identity()
    if not ctx.journal then
        local scheduler
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok then scheduler = UIManager end
        ctx.journal = require("kamarejournal"):new{ scheduler = scheduler }
        ctx.journal:load()
    end
    return ctx
end

-- Tier 3: identity + queue. Never auto-starts (Queue:load always restores
-- paused), so probing queue_state cannot begin a download.
local function ensure_queue()
    local ctx = ensure_identity()
    if not ctx.queue then
        local scheduler
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok then scheduler = UIManager end
        ctx.queue = require("kamarecachequeue"):new{
            store = ctx.store,
            settings = ctx.settings,
            client = ctx.client,
            scheduler = scheduler,
        }
        ctx.queue:load()
    end
    return ctx
end

-- Trim + drop trailing slashes, keep path prefixes and scheme/host verbatim.
local function normalize_url(url)
    if type(url) ~= "string" then return nil end
    local trimmed = url:match("^%s*(.-)%s*$")
    trimmed = trimmed:gsub("/+$", "")
    return trimmed
end

-- Read-only key lookup: never creates a key as a side effect. The normalized
-- form is tried as a fallback so a caller may pass a trailing slash.
local function find_key(ctx, base_url)
    if not base_url or base_url == "" then return nil end
    local key = ctx.store:find_server_key(ctx.settings, { base_url = base_url })
    if key then return key end
    local normalized = normalize_url(base_url)
    if normalized and normalized ~= base_url then
        key = ctx.store:find_server_key(ctx.settings, { base_url = normalized })
    end
    return key
end

local function servers_of(settings)
    local servers = settings:readSetting("servers", {})
    if type(servers) ~= "table" then servers = {} end
    return servers
end

local function existing_keys(servers)
    local keys = {}
    for __, s in ipairs(servers) do
        if type(s) == "table" and s.key then keys[#keys + 1] = s.key end
    end
    return keys
end

function Cache.resolve_server_key(base_url)
    if not base_url or base_url == "" then return nil end
    local ctx = ensure_identity()
    return ctx.store:resolve_server_key(ctx.settings, { base_url = base_url })
end

-- Write: mirror Moon's server configuration. Idempotent; a hit updates the URL
-- and API key in place and keeps the cache key, so rotating a key never loses
-- downloads (spec 01 A3 / 02 A6). Never creates a queue, a journal or a cache
-- directory, and never talks to the network.
function Cache.register_server(server)
    if type(server) ~= "table" then
        return nil, "base_url_required", _("Server URL required")
    end
    local base_url = normalize_url(server.base_url or server.url or server.kavita_url)
    if not base_url or base_url == "" then
        return nil, "base_url_required", _("Server URL required")
    end
    local api_key = server.api_key
    if type(api_key) ~= "string" or api_key == "" then
        return nil, "api_key_required", _("API key required")
    end

    local ctx = ensure_identity()
    local settings = ctx.settings
    local servers = servers_of(settings)

    local entry
    for __, s in ipairs(servers) do
        if type(s) == "table" then
            local s_url = normalize_url(s.kavita_url) or normalize_url(s.url)
            if s_url and s_url == base_url then
                entry = s
                break
            end
        end
    end
    if not entry and server.name then
        for __, s in ipairs(servers) do
            if type(s) == "table" and s.name == server.name then
                entry = s
                break
            end
        end
    end

    local changed = false
    if not entry then
        entry = {
            name = server.name or (base_url:match("^%a+://([^/]+)") or base_url),
            kavita_url = base_url,
            url = base_url,
            api_key = api_key,
            key = ctx.store:generate_server_key(existing_keys(servers)),
            updated_at = os.time(),
        }
        servers[#servers + 1] = entry
        changed = true
    else
        if entry.kavita_url ~= base_url then
            entry.kavita_url = base_url
            changed = true
        end
        if entry.url ~= base_url then
            entry.url = base_url
            changed = true
        end
        if entry.api_key ~= api_key then
            entry.api_key = api_key
            changed = true
        end
        if not entry.key or entry.key == "" then
            -- Kamare's own server editor replaces the whole table and drops
            -- the key; restore it so existing cache keeps its owner.
            entry.key = ctx.store:generate_server_key(existing_keys(servers))
            changed = true
        end
        if changed then entry.updated_at = os.time() end
    end

    -- Keep the shared client singleton in sync (never authenticate here).
    ctx.client.base_url = base_url
    ctx.client.api_key = api_key
    ctx.client.auth_method = "apiKey"
    ctx.client.bearer = nil

    if changed then
        settings:saveSetting("servers", servers)
        local ok, flushed = pcall(function() return settings:flush() end)
        if not ok or flushed == false then
            logger.warn("[kamare:cache] could not persist the server mirror:", tostring(flushed))
            return nil, "settings_write_failed", _("Could not save the server configuration")
        end
    end
    return entry.key
end

-- Read-only. No side effects beyond a missing derived index being rebuilt.
function Cache.status(base_url, chapter_id)
    if not chapter_id then return nil end
    chapter_id = tonumber(chapter_id) or chapter_id
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil end

    for __, entry in ipairs(ctx.store:load_index_or_rebuild(key)) do
        if entry.chapterId == chapter_id then
            local stale = entry.stale == true
            return {
                state = stale and "stale" or "complete",
                bytes = tonumber(entry.pagesBytes) or tonumber(entry.archiveBytes) or 0,
                total = tonumber(entry.archiveBytes) or tonumber(entry.pagesBytes) or 0,
            }
        end
    end

    local part = ctx.store:file_size(ctx.store:part_path(key, chapter_id))
    if part > 0 then
        return { state = "partial", bytes = part, total = 0 }
    end
    return nil
end

-- Read-only.
function Cache.summary(base_url)
    local ctx = ensure_identity()
    local used, chapters, available
    if base_url and base_url ~= "" then
        local key = find_key(ctx, base_url)
        if not key then return { used = 0, available = ctx.store:free_bytes() or 0, chapters = 0 } end
        local usage = ctx.store:server_usage(key)
        used, chapters = usage.used, usage.chapters
    else
        local usage = ctx.store:total_usage()
        used, chapters = usage.used, usage.chapters
    end
    available = ctx.store:free_bytes() or 0
    return { used = used, available = available, chapters = chapters }
end

-- Read-only: 1-based, clamped. Journal position first, then the cached page
-- snapshot, otherwise page 1 with no source. Never lazily creates a server key
-- and never writes the journal.
function Cache.resume_page(base_url, chapter_id, series_id)
    if not base_url or base_url == "" then return nil, "base_url_required" end
    if not chapter_id then return nil end

    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_read()

    local id = tonumber(chapter_id) or chapter_id
    local sid = series_id
    if sid == nil then
        for __, entry in ipairs(ctx.store:load_index_or_rebuild(key)) do
            if entry.chapterId == id then
                sid = entry.seriesId
                break
            end
        end
    end
    local pos = ctx.journal:get_position(key, id)
    if sid == nil and pos then sid = pos.seriesId end

    local meta = sid ~= nil and ctx.store:read_meta(key, sid, id) or nil
    if not meta and not pos then return nil end

    local snapshot = meta and tonumber(meta.pagesReadSnapshot) or nil
    local pages = meta and tonumber(meta.pages) or nil
    local journal_page = pos and tonumber(pos.pageNum) or nil
    if journal_page and journal_page <= 0 then journal_page = nil end

    local source
    if journal_page then
        source = "journal"
    elseif snapshot and snapshot > 0 then
        source = "snapshot"
    end

    return {
        page = CacheUtil.resolve_start_page(journal_page, snapshot, pages),
        source = source,
        status = pos and pos.status or nil,
        updated_at = pos and pos.ts or nil,
    }
end

local function map_entry(base_url, key, entry, series_hint)
    if type(entry) ~= "table" then return nil end
    local chapter_id = entry.chapterId or entry.chapter_id or entry.id
    if not chapter_id then return nil end
    local series_id = entry.seriesId or entry.series_id or series_hint
    if not series_id then return nil end
    local bytes = entry.archiveBytes or entry.bytes
    local files = entry.files
    if not bytes and type(files) == "table" then
        bytes = 0
        for __, f in ipairs(files) do bytes = bytes + (tonumber(f.bytes) or 0) end
    end
    return {
        serverKey = key,
        serverUrl = base_url,
        seriesId = series_id,
        seriesName = entry.seriesName or entry.series_name,
        libraryId = entry.libraryId or entry.library_id,
        volumeId = entry.volumeId or entry.volume_id,
        volumeName = entry.volumeName or entry.volume_name,
        chapterId = chapter_id,
        chapterTitle = entry.chapterTitle or entry.chapter_title or entry.title,
        chapterNumber = entry.chapterNumber or entry.chapter_number or entry.number,
        order = entry.order,
        pages = entry.pages,
        archiveBytes = bytes,
        archiveExt = entry.archiveExt,
        koreaderHash = entry.koreaderHash or entry.koreader_hash,
        files = files,
        pagesReadSnapshot = entry.pagesReadSnapshot or entry.pages_read,
        seriesChapters = entry.seriesChapters or entry.series_chapters,
    }
end

-- Write: adds chapters to Kamare's single download queue.
-- entries = array of chapter descriptors (Moon's toc entries are accepted as-is).
function Cache.enqueue(base_url, entries, opts)
    if not base_url or base_url == "" then
        return nil, "base_url_required", _("Server URL required")
    end
    if type(entries) ~= "table" or #entries == 0 then
        return nil, "entries_required", _("Nothing to download")
    end
    local ctx = ensure_queue()
    local key = Cache.resolve_server_key(base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end

    local mapped = {}
    for __, entry in ipairs(entries) do
        local item = map_entry(base_url, key, entry)
        if item then mapped[#mapped + 1] = item end
    end
    if #mapped == 0 then return nil, "entries_required", _("No valid entries") end
    return ctx.queue:enqueue(mapped, opts)
end

-- Read-only queue projection. The queue is global, so `state` is global too,
-- while entries / bytes / current / last_error are filtered to this server
-- (spec 01 A3 / 07 A4).
function Cache.queue_state(base_url)
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_queue()
    local queue = ctx.queue

    local entries = {}
    local bytes_done, bytes_total, count = 0, 0, 0
    local last_error
    for __, entry in ipairs(queue.entries or {}) do
        if entry.serverKey == key then
            local done, total = queue:entry_progress(entry)
            done = tonumber(done) or 0
            total = tonumber(total) or tonumber(entry.archiveBytes) or 0
            entries[entry.chapterId] = {
                chapterId = entry.chapterId,
                seriesId = entry.seriesId,
                state = entry.state,
                bytes_done = done,
                bytes_total = total,
                attempts = entry.attempts,
                last_error = entry.lastError,
            }
            bytes_done = bytes_done + done
            bytes_total = bytes_total + total
            count = count + 1
            if entry.state == "failed" and entry.lastError then
                last_error = entry.lastError
            end
        end
    end

    local current = queue.current
    return {
        state = queue.state,
        percent = bytes_total > 0 and math.max(0, math.min(1, bytes_done / bytes_total)) or 0,
        bytes_done = bytes_done,
        bytes_total = bytes_total,
        pending_count = count,
        current_chapter_id = (current and current.serverKey == key) and current.chapterId or nil,
        pause_reason = queue.pause_reason,
        last_error = last_error,
        entries = entries,
    }
end

-- Write: pauses the single shared queue (affects every server, documented).
function Cache.queue_pause(base_url)
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_queue()
    local queue = ctx.queue
    if #(queue.entries or {}) == 0 then
        -- Nothing to pause; keep queue_state honest instead of reporting
        -- "paused" for an empty queue.
        return true
    end
    queue:pause("user")
    return true
end

-- Write: resumes the shared queue. An empty queue is a no-op.
function Cache.queue_resume(base_url)
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_queue()
    ctx.queue:resume()
    return true
end

-- Write: revives only this server's queued/failed entries, then restarts the
-- queue. `Queue:retry` resets the consecutive-failure counter.
function Cache.queue_retry(base_url, chapter_ids)
    if not base_url or base_url == "" then
        return nil, "base_url_required", _("Server URL required")
    end
    if type(chapter_ids) ~= "table" then
        return nil, "chapter_ids_required", _("Chapter ids required")
    end
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_queue()
    local queue = ctx.queue

    local revived = 0
    for __, chapter_id in ipairs(chapter_ids) do
        local id = tonumber(chapter_id) or chapter_id
        for __, entry in ipairs(queue.entries or {}) do
            if entry.serverKey == key and entry.chapterId == id
                and (entry.state == "queued" or entry.state == "failed") then
                queue:retry(key, id)
                revived = revived + 1
                break
            end
        end
    end
    if revived == 0 then return nil, "retry_no_entry", _("Nothing to retry") end
    return true
end

local function cover_path_for(ctx, key, series_id)
    local path = ctx.store:cover_path(key, series_id)
    if ctx.store:exists(path) then return path end
    local dir = ctx.store:series_dir(key, series_id)
    for __, name in ipairs(ctx.store:list_dir(dir)) do
        if name:match("^cover%.") then return dir .. "/" .. name end
    end
    return nil
end

-- Read-only shelf projection of index.json (no per-chapter scan). An unknown
-- server returns nil so the caller renders "no cache" instead of an error.
function Cache.index(base_url)
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_read()

    local series = {}
    local series_names = {}
    for __, entry in ipairs(ctx.store:load_index_or_rebuild(key)) do
        local sid = tostring(entry.seriesId)
        local item = series[sid]
        if not item then
            item = {
                seriesId = entry.seriesId,
                seriesName = entry.seriesName,
                chapters = 0,
                complete = false,
                stale = false,
                bytes = 0,
            }
            series[sid] = item
        end
        item.chapters = item.chapters + 1
        if entry.seriesName then item.seriesName = entry.seriesName end
        if not item.seriesName then
            -- index entries normally carry the name; fall back to series.json.
            if series_names[sid] == nil then
                local series_json = ctx.store:read_series(key, entry.seriesId)
                series_names[sid] = (series_json and series_json.seriesName) or false
            end
            if series_names[sid] then item.seriesName = series_names[sid] end
        end
        if entry.stale == true then
            item.stale = true
        elseif entry.state == nil or entry.state == "complete" then
            item.complete = true
        end
        item.bytes = item.bytes + (tonumber(entry.pagesBytes)
            or tonumber(entry.archiveBytes) or 0)
    end

    for __, pos in ipairs(ctx.journal:all_positions()) do
        if pos.serverKey == key then
            local item = series[tostring(pos.seriesId)]
            local ts = tonumber(pos.ts) or 0
            if item and ts > (item.lastReadAt or -1) then item.lastReadAt = ts end
        end
    end

    for sid, item in pairs(series) do
        item.coverPath = cover_path_for(ctx, key, sid)
    end

    return {
        used = ctx.store:server_usage(key).used,
        available = ctx.store:free_bytes(),
        series = series,
    }
end

-- Read-only capacity estimate. Reuses the queue's hydration and space rules;
-- writes nothing, enqueues nothing, creates no server key (spec 01 A8 / 07 A6).
function Cache.estimate(base_url, entries)
    if not base_url or base_url == "" then
        return nil, "base_url_required", _("Server URL required")
    end
    local ctx = ensure_identity()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end
    ctx = ensure_queue()
    local queue = ctx.queue
    local Queue = require("kamarecachequeue")
    local factor = tonumber(queue.PEAK_FACTOR) or Queue.PEAK_FACTOR
    local low_water = tonumber(queue.LOW_WATER_BYTES) or Queue.LOW_WATER_BYTES

    local chapters, bytes = 0, 0
    for __, raw in ipairs(entries or {}) do
        local item = map_entry(base_url, key, raw)
        if not item and type(raw) == "table" then
            local id = raw.chapterId or raw.chapter_id or raw.id
            if id then
                item = {
                    serverKey = key,
                    serverUrl = base_url,
                    chapterId = id,
                    seriesId = raw.seriesId or raw.series_id,
                    pages = raw.pages,
                    archiveBytes = raw.archiveBytes or raw.bytes,
                    files = raw.files,
                }
            end
        end
        if item then
            local id = tonumber(item.chapterId) or item.chapterId
            item.chapterId = id
            local queued = queue:contains(key, id)
            local cached = item.seriesId ~= nil
                and ctx.store:has_meta(key, item.seriesId, id)
            if not queued and not cached then
                local copy = {}
                for k, v in pairs(item) do copy[k] = v end
                local ok = queue:_hydrate(copy)
                if ok then
                    local series_id = copy.seriesId or item.seriesId
                    if not (series_id and ctx.store:has_meta(key, series_id, id)) then
                        chapters = chapters + 1
                        bytes = bytes + (tonumber(copy.archiveBytes) or 0) * factor
                    end
                end
            end
        end
    end

    local available = ctx.store:free_bytes()
    local reason
    if chapters == 0 then
        reason = "nothing_to_do"
    else
        local limit_mb = 0
        if ctx.settings then
            limit_mb = tonumber(ctx.settings:readSetting("cache_limit_mb", 0)) or 0
        end
        if limit_mb > 0 then
            local limit = limit_mb * 1024 * 1024
            local used = ctx.store:total_usage().used
            if used + bytes > limit then reason = "space" end
        end
        if not reason and available and bytes > available then
            reason = "space"
        end
        if not reason and available and available < low_water then
            reason = "low_water"
        end
    end

    return {
        chapters = chapters,
        bytes = bytes,
        available = available,
        ok = reason == nil,
        reason = reason,
    }
end

-- The viewer currently holding the screen, if any. Returns chapter id + the
-- cache server key it was opened against (nil for an online stream).
local function open_chapter()
    local ok, viewer = pcall(require, "kamareimageviewer")
    if not ok or type(viewer) ~= "table" then return nil end
    local active = viewer.active_instance
    if type(active) ~= "table" then return nil end
    local metadata = active.metadata or {}
    local chapter_id = tonumber(metadata.chapterId or metadata.chapter_id
        or active.chapterId)
    if not chapter_id then return nil end
    return chapter_id, active.cache_server_key
end

-- Write: deletes cached chapters (files + part + queue entry). Never the journal.
function Cache.delete(base_url, chapter_ids)
    if not base_url or base_url == "" then
        return nil, "base_url_required", _("Server URL required")
    end
    if type(chapter_ids) ~= "table" then
        return nil, "chapter_ids_required", _("Chapter ids required")
    end
    local ctx = ensure_queue()
    local key = find_key(ctx, base_url)
    if not key then return nil, "unknown_server", _("Unknown server") end

    -- All-or-nothing delete protection: if any requested chapter is on screen,
    -- nothing is removed and no queue entry is aborted (spec 07 A1).
    local open_id, open_key = open_chapter()
    if open_id then
        for __, chapter_id in ipairs(chapter_ids) do
            local id = tonumber(chapter_id) or chapter_id
            if id == open_id and (open_key == nil or open_key == key) then
                return nil, "chapter_open", _("This chapter is open; close it first")
            end
        end
    end

    local by_id = {}
    for __, entry in ipairs(ctx.store:load_index_or_rebuild(key)) do
        by_id[entry.chapterId] = entry
    end

    local deleted = 0
    for __, chapter_id in ipairs(chapter_ids) do
        local id = tonumber(chapter_id) or chapter_id
        local entry = by_id[id]
        local part = ctx.store:part_path(key, id)
        -- Capture this before abort: abort removes the .part now, and the
        -- "deleted" count keeps its old meaning (an index entry or bytes on
        -- disk were actually removed).
        local had_part = ctx.store:file_size(part) > 0
        if ctx.queue:contains(key, id) then ctx.queue:abort(key, id) end
        if entry then
            ctx.store:delete_chapter(key, entry.seriesId, id)
            deleted = deleted + 1
        else
            os.remove(part)
            ctx.store:remove_index_chapter(key, nil, id)
            if had_part then deleted = deleted + 1 end
        end
    end
    return true, nil, deleted
end

local function is_offline(ctx)
    if ctx.settings and ctx.settings:readSetting("force_offline", false) then
        return true
    end
    local ok, network = pcall(require, "ui/network/manager")
    if ok and network and network.isOnline then
        local pok, online = pcall(network.isOnline, network)
        if pok and online == false then return true end
    end
    return false
end

-- Map Kamare's file-dimensions payload to the viewer's 1-based shape.
local function dimensions_from_client(client, chapter_id)
    if not client or not client.getFileDimensions then return nil end
    local ok, dims = pcall(client.getFileDimensions, client, chapter_id)
    if not ok or type(dims) ~= "table" or #dims == 0 then return nil end
    local zero_based = false
    for __, d in ipairs(dims) do
        local page = d.pageNumber or d.page or d.page_num
        if type(page) == "number" and page == 0 then
            zero_based = true
            break
        end
    end
    local out = {}
    for __, d in ipairs(dims) do
        local page = d.pageNumber or d.page or d.page_num
        if zero_based and type(page) == "number" then page = page + 1 end
        if type(page) == "number" then
            local w = tonumber(d.width) or 0
            local h = tonumber(d.height) or 0
            out[page] = {
                pageNumber = page, width = w, height = h, isWide = w > h,
                fileName = d.fileName or string.format("%04d.jpg", page),
            }
        end
    end
    return out
end

local function iswide_map(dimensions)
    local out = {}
    if type(dimensions) == "table" then
        for __, d in ipairs(dimensions) do
            local page = d.pageNumber or d.page or d.page_num
            if type(page) == "number" then out[page] = d.isWide and true or false end
        end
    end
    return out
end

-- Write UI: the one public viewer entry. Decides cache-first, offline, start
-- page and viewer lifecycle here so Moon does not re-implement any of it.
function Cache.open(opts)
    opts = type(opts) == "table" and opts or {}
    local base_url = opts.base_url
    if not base_url or base_url == "" then
        return nil, "base_url_required", _("Server URL required")
    end
    if not opts.api_key or opts.api_key == "" then
        return nil, "api_key_required", _("API key required")
    end

    local key, code, message = Cache.register_server{
        base_url = base_url, api_key = opts.api_key,
    }
    if not key then return nil, code, message end

    local viewer_ok, viewer_mod = pcall(require, "kamareimageviewer")
    if viewer_ok and type(viewer_mod) == "table" and viewer_mod.active_instance then
        return nil, "viewer_running", _("A viewer is already open")
    end

    local entry = opts.entry
    if type(entry) ~= "table" then
        return nil, "entries_required", _("Chapter entry required")
    end
    local chapter_id = tonumber(entry.chapterId or entry.chapter_id or entry.id)
    if not chapter_id then
        return nil, "entries_required", _("Chapter entry required")
    end
    local series_id = entry.seriesId or entry.series_id

    local ctx = ensure_identity()
    local meta = series_id ~= nil and ctx.store:read_meta(key, series_id, chapter_id) or nil
    local pages = (meta and tonumber(meta.pages)) or tonumber(entry.pages)
        or (type(entry.files) == "table" and #entry.files) or 0
    if pages <= 0 then return nil, "no_pages", _("This chapter has no pages") end

    local offline = is_offline(ctx)
    if offline and not meta then
        return nil, "offline_not_cached", _("Not cached · connect to download")
    end

    local start_page = tonumber(opts.start_page)
    if start_page then
        start_page = math.max(1, math.min(start_page, pages))
    elseif meta then
        ctx = ensure_read()
        local resume = Cache.resume_page(base_url, chapter_id, series_id)
        start_page = resume and resume.page or 1
    elseif not offline and ctx.client and ctx.client.getReaderProgress then
        local pok, progress = pcall(ctx.client.getReaderProgress, ctx.client, chapter_id)
        local page = pok and progress and tonumber(progress.pageNum) or nil
        start_page = page and math.min(math.max(1, page + 1), pages) or 1
    else
        start_page = 1
    end

    local preloaded_dimensions
    if meta and type(meta.dims) == "table" and #meta.dims > 0 then
        preloaded_dimensions = {}
        for i, dim in ipairs(meta.dims) do
            local w, h = dim[1] or 0, dim[2] or 0
            preloaded_dimensions[i] = {
                pageNumber = i, width = w, height = h, isWide = w > h,
                fileName = string.format("%04d.jpg", i),
            }
        end
    else
        preloaded_dimensions = dimensions_from_client(ctx.client, chapter_id)
    end

    local images_list_data
    if ctx.client and ctx.client.streamChapter then
        local sok, stream = pcall(ctx.client.streamChapter, ctx.client, chapter_id)
        if sok then images_list_data = stream end
    end

    local metadata = {
        seriesName = opts.title or (meta and meta.seriesName),
        seriesId = series_id,
        libraryId = entry.libraryId or entry.library_id or (meta and meta.libraryId),
        volumeId = entry.volumeId or entry.volume_id or (meta and meta.volumeId),
        chapterId = chapter_id,
        chapterTitle = (meta and meta.chapterTitle) or entry.chapterTitle
            or entry.chapter_title or opts.title,
        startPage = start_page,
        content_type = opts.content_type or entry.content_type or "auto",
        serverKey = key,
        offline = offline,
    }

    if not viewer_ok or type(viewer_mod) ~= "table" or type(viewer_mod.new) ~= "function" then
        return nil, nil, _("The viewer is not available")
    end
    local viewer = viewer_mod:new{
        ui = nil,
        images_list_data = images_list_data,
        title = opts.title or (meta and meta.seriesName) or _("Manga"),
        fullscreen = true,
        with_title_bar = false,
        images_list_nb = pages,
        preloaded_dimensions = preloaded_dimensions,
        preloaded_iswide = is_wide_map(preloaded_dimensions),
        metadata = metadata,
        kamare_settings = ctx.settings,
        override_view_mode = opts.override_view_mode,
        page_source = meta and "local" or nil,
        offline = offline,
        local_meta = meta,
        cache_store = meta and ctx.store or nil,
        cache_server_key = key,
        cache_journal = meta and ctx.journal or nil,
        on_close_callback = opts.on_close,
        on_next_chapter_callback = opts.on_next,
    }
    if type(viewer) ~= "table" then
        return nil, nil, _("Could not open the viewer")
    end
    if viewer._aborted then
        return nil, "viewer_running", _("A viewer is already open")
    end

    local uok, UIManager = pcall(require, "ui/uimanager")
    if uok and UIManager and UIManager.show then
        pcall(UIManager.show, UIManager, viewer)
    end
    return viewer
end

return Cache
