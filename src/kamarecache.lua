--[[--
Public cache facade for other plugins (Moon is the only intended consumer).

Contract (API_VERSION = 1):
  cache.api_version            -> 1
  cache.capabilities           -> { status, enqueue, delete, summary }
  cache.status(base_url, id)   -> nil | { state = "partial"|"complete"|"stale", bytes, total }
  cache.summary(base_url)      -> { used, available, chapters }
  cache.enqueue(base_url, entries, opts) -> true | nil, err
  cache.delete(base_url, chapter_ids)    -> true | nil, err, deleted

Calls always take `base_url`; the internal serverKey is resolved here so
callers never depend on Kamare's storage details. Read-only calls have no side
effects. Writes only touch Kamare's own queue and cache directory; the reading
journal is never modified.

Capability probing (spec 09): `pcall(require, "kamarecache")` + api_version +
capabilities. Missing module or a different major version means "no cache UI",
silently -- never raise at the caller.
--]]

local Cache = {}

Cache.api_version = 1
Cache.capabilities = {
    status = true,
    enqueue = true,
    delete = true,
    summary = true,
}

local context

local function lazy_journal_module()
    return require("kamarejournal")
end

function Cache.set_context(ctx)
    context = context or {}
    for key, value in pairs(ctx or {}) do
        if value ~= nil then context[key] = value end
    end
    return true
end

function Cache.get_context()
    return context
end

local function ensure_context()
    if not context then context = {} end
    if not context.store then
        context.store = require("kamarecachestore"):new{}
    end
    if not context.settings then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        context.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kamare.lua")
    end
    if not context.journal then
        local scheduler
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok then scheduler = UIManager end
        context.journal = lazy_journal_module():new{ scheduler = scheduler }
        context.journal:load()
    end
    if not context.client then
        context.client = require("kavitaclient")
    end
    if not context.queue then
        context.queue = require("kamarecachequeue"):new{
            store = context.store,
            settings = context.settings,
            client = context.client,
        }
        context.queue:load()
    end
    return context
end

function Cache.resolve_server_key(base_url)
    if not base_url or base_url == "" then return nil end
    local ctx = ensure_context()
    return ctx.store:resolve_server_key(ctx.settings, { base_url = base_url })
end

-- Read-only key lookup: never creates a key as a side effect.
local function find_key(ctx, base_url)
    if not base_url or base_url == "" then return nil end
    return ctx.store:find_server_key(ctx.settings, { base_url = base_url })
end

-- Read-only. No side effects beyond a missing index being rebuilt.
function Cache.status(base_url, chapter_id)
    if not chapter_id then return nil end
    local ctx = ensure_context()
    local key = find_key(ctx, base_url)
    if not key then return nil end

    for _, entry in ipairs(ctx.store:load_index_or_rebuild(key)) do
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
    local ctx = ensure_context()
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
        for _, f in ipairs(files) do bytes = bytes + (tonumber(f.bytes) or 0) end
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
    if not base_url or base_url == "" then return nil, "base_url required" end
    if type(entries) ~= "table" or #entries == 0 then return nil, "entries required" end
    local ctx = ensure_context()
    local key = Cache.resolve_server_key(base_url)
    if not key then return nil, "unknown server" end

    local mapped = {}
    for _, entry in ipairs(entries) do
        local item = map_entry(base_url, key, entry)
        if item then mapped[#mapped + 1] = item end
    end
    if #mapped == 0 then return nil, "no valid entries" end
    return ctx.queue:enqueue(mapped, opts)
end

-- Write: deletes cached chapters (files + part + queue entry). Never the journal.
function Cache.delete(base_url, chapter_ids)
    if not base_url or base_url == "" then return nil, "base_url required" end
    if type(chapter_ids) ~= "table" then return nil, "chapter_ids required" end
    local ctx = ensure_context()
    local key = Cache.resolve_server_key(base_url)
    if not key then return nil, "unknown server" end

    local by_id = {}
    for _, entry in ipairs(ctx.store:load_index_or_rebuild(key)) do
        by_id[entry.chapterId] = entry
    end

    local deleted = 0
    for _, chapter_id in ipairs(chapter_ids) do
        local id = tonumber(chapter_id) or chapter_id
        local entry = by_id[id]
        if ctx.queue:contains(key, id) then ctx.queue:abort(key, id) end
        if entry then
            ctx.store:delete_chapter(key, entry.seriesId, id)
            deleted = deleted + 1
        else
            local part = ctx.store:part_path(key, id)
            local had_part = ctx.store:file_size(part) > 0
            os.remove(part)
            ctx.store:remove_index_chapter(key, nil, id)
            if had_part then deleted = deleted + 1 end
        end
    end
    return true, nil, deleted
end

return Cache
