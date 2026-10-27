--[[--
Local cache store for Kavita chapters.

Owns every path and every JSON document under `<data dir>/kamare/cache`:

    <cache>/<serverKey>/index.json
    <cache>/<serverKey>/.incoming/<chapterId>.part
    <cache>/<serverKey>/<seriesId>/series.json
    <cache>/<serverKey>/<seriesId>/cover.jpg
    <cache>/<serverKey>/<seriesId>/<chapterId>/meta.json
    <cache>/<serverKey>/<seriesId>/<chapterId>/0001.jpg ...

`meta.json` is the integrity proof: it is written atomically only after every
page has been extracted and validated, so "meta exists" == "chapter is complete".

This module is pure data/IO. It must never require UI modules at file scope so
it can be unit tested under plain LuaJIT (see spec/).
--]]

local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local logger = require("logger")

local Store = {}
Store.__index = Store

Store.VERSION = 1
Store.LOW_WATER_BYTES = 500 * 1024 * 1024

local function now()
    return os.time()
end

local function ensure_dir(path)
    if not path or path == "" then return nil, "empty path" end
    local acc
    if path:sub(1, 1) == "/" then
        acc = "/"
    else
        acc = ""
    end
    for part in path:gmatch("[^/]+") do
        if acc == "/" then
            acc = "/" .. part
        elseif acc == "" then
            acc = part
        else
            acc = acc .. "/" .. part
        end
        local mode = lfs.attributes(acc, "mode")
        if mode == nil then
            local ok, err = lfs.mkdir(acc)
            if not ok then
                return nil, string.format("mkdir %s: %s", acc, tostring(err))
            end
        elseif mode ~= "directory" then
            return nil, acc .. " exists and is not a directory"
        end
    end
    return true
end

local function remove_tree(path)
    local attr = lfs.attributes(path)
    if not attr then return true end
    if attr.mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local ok, err = remove_tree(path .. "/" .. name)
                if not ok then return nil, err end
            end
        end
        local ok, err = lfs.rmdir(path)
        if not ok then return nil, err end
    else
        local ok, err = os.remove(path)
        if not ok then return nil, err end
    end
    return true
end

-- Iterative walk that returns the total byte size of every regular file below
-- `path` (symlinks are followed only for stat, never descended).
local function size_of_tree(path)
    local attr = lfs.attributes(path)
    if not attr then return 0 end
    if attr.mode == "file" then return attr.size or 0 end
    if attr.mode ~= "directory" then return 0 end
    local total = 0
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            total = total + size_of_tree(path .. "/" .. name)
        end
    end
    return total
end

local function list_dir(path)
    local names = {}
    if not path or lfs.attributes(path, "mode") ~= "directory" then return names end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function is_dir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil, "open failed" end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local ok, err = ensure_dir(path:match("^(.*)/[^/]+$") or ".")
    if not ok then return nil, err end
    local tmp = path .. ".tmp"
    local f, ferr = io.open(tmp, "wb")
    if not f then return nil, tostring(ferr) end
    local wok, werr = f:write(data)
    f:close()
    if not wok then
        os.remove(tmp)
        return nil, tostring(werr)
    end
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        os.remove(tmp)
        return nil, tostring(rerr)
    end
    return true
end

function Store:new(opts)
    opts = opts or {}
    local o = {
        data_dir = opts.data_dir,
        settings_dir = opts.settings_dir,
        clock = opts.clock or now,
    }
    return setmetatable(o, self)
end

function Store:_data_dir()
    if self.data_dir then return self.data_dir end
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir()
end

function Store:cache_root()
    return self:_data_dir() .. "/kamare/cache"
end

function Store:server_root(server_key)
    return self:cache_root() .. "/" .. tostring(server_key)
end

function Store:series_dir(server_key, series_id)
    return self:server_root(server_key) .. "/" .. tostring(series_id)
end

function Store:chapter_dir(server_key, series_id, chapter_id)
    return self:series_dir(server_key, series_id) .. "/" .. tostring(chapter_id)
end

function Store:incoming_dir(server_key)
    return self:server_root(server_key) .. "/.incoming"
end

function Store:part_path(server_key, chapter_id)
    return self:incoming_dir(server_key) .. "/" .. tostring(chapter_id) .. ".part"
end

function Store:page_path(server_key, series_id, chapter_id, page_no, ext)
    local extension = tostring(ext or "jpg"):gsub("^%.", "")
    return self:chapter_dir(server_key, series_id, chapter_id)
        .. string.format("/%04d.%s", page_no, extension)
end

function Store:cover_path(server_key, series_id)
    return self:series_dir(server_key, series_id) .. "/cover.jpg"
end

function Store:meta_path(server_key, series_id, chapter_id)
    return self:chapter_dir(server_key, series_id, chapter_id) .. "/meta.json"
end

function Store:series_path(server_key, series_id)
    return self:series_dir(server_key, series_id) .. "/series.json"
end

function Store:index_path(server_key)
    return self:server_root(server_key) .. "/index.json"
end

function Store:ensure_dir(path)
    return ensure_dir(path)
end

function Store:read_json(path)
    local data, err = read_file(path)
    if not data then return nil, err end
    local ok, decoded = pcall(rapidjson.decode, data)
    if not ok or type(decoded) ~= "table" then
        logger.warn("[kamare:cache] corrupt JSON:", path, tostring(decoded))
        return nil, "invalid JSON"
    end
    return decoded
end

function Store:write_json_atomic(path, tbl)
    local ok, encoded = pcall(rapidjson.encode, tbl)
    if not ok or type(encoded) ~= "string" then
        logger.warn("[kamare:cache] encode failed:", path, tostring(encoded))
        return nil, "encode failed"
    end
    return write_file(path, encoded)
end

function Store:write_file_atomic(path, bytes)
    if type(bytes) ~= "string" then return nil, "bytes must be a string" end
    return write_file(path, bytes)
end

function Store:file_size(path)
    local attr = lfs.attributes(path)
    return (attr and attr.size) or 0
end

function Store:list_dir(path)
    return list_dir(path)
end

function Store:exists(path)
    return lfs.attributes(path) ~= nil
end

-- ---- meta ----------------------------------------------------------------

function Store:read_meta(server_key, series_id, chapter_id)
    local meta = self:read_json(self:meta_path(server_key, series_id, chapter_id))
    if type(meta) ~= "table" then return nil end
    return meta
end

function Store:write_meta(meta)
    if type(meta) ~= "table" or not meta.serverKey or not meta.seriesId or not meta.chapterId then
        return nil, "meta missing identity"
    end
    meta.v = meta.v or self.VERSION
    meta.state = meta.state or "complete"
    meta.cachedAt = meta.cachedAt or self.clock()
    local ok, err = self:write_json_atomic(
        self:meta_path(meta.serverKey, meta.seriesId, meta.chapterId), meta)
    return ok, err
end

function Store:has_meta(server_key, series_id, chapter_id)
    return self:exists(self:meta_path(server_key, series_id, chapter_id))
end

-- ---- series --------------------------------------------------------------

function Store:read_series(server_key, series_id)
    local series = self:read_json(self:series_path(server_key, series_id))
    if type(series) ~= "table" then return nil end
    return series
end

function Store:write_series(server_key, series)
    if type(series) ~= "table" or not series.seriesId then
        return nil, "series missing seriesId"
    end
    series.v = series.v or self.VERSION
    series.updatedAt = series.updatedAt or self.clock()
    return self:write_json_atomic(self:series_path(server_key, series.seriesId), series)
end

function Store:read_cover(server_key, series_id)
    return read_file(self:cover_path(server_key, series_id))
end

function Store:write_cover(server_key, series_id, bytes, ext)
    if type(bytes) ~= "string" or #bytes == 0 then return nil, "empty cover" end
    local path = self:cover_path(server_key, series_id)
    if ext and ext:lower() ~= "jpg" and ext:lower() ~= "jpeg" then
        path = self:series_dir(server_key, series_id) .. "/cover." .. ext:lower()
    end
    return self:write_file_atomic(path, bytes)
end

-- ---- index ---------------------------------------------------------------

local function meta_to_index_entry(meta, stale)
    return {
        seriesId = meta.seriesId,
        seriesName = meta.seriesName,
        libraryId = meta.libraryId,
        chapterId = meta.chapterId,
        chapterTitle = meta.chapterTitle,
        chapterNumber = meta.chapterNumber,
        order = meta.order,
        pages = meta.pages,
        archiveBytes = meta.archiveBytes,
        pagesBytes = meta.pagesBytes,
        state = meta.state or "complete",
        stale = stale and true or false,
        cachedAt = meta.cachedAt,
    }
end

local function entry_less(a, b)
    local an = a.seriesName or ""
    local bn = b.seriesName or ""
    if an ~= bn then return an < bn end
    local ao = tonumber(a.order) or 0
    local bo = tonumber(b.order) or 0
    if ao ~= bo then return ao < bo end
    return (tonumber(a.chapterId) or 0) < (tonumber(b.chapterId) or 0)
end

local function to_array(tbl)
    -- rapidjson tags decoded objects and arrays with different metatables and
    -- still encodes a tagged empty object as {}. Always hand back a plain Lua
    -- sequence so callers can append to it.
    local out = {}
    if type(tbl) == "table" then
        for _, v in ipairs(tbl) do out[#out + 1] = v end
    end
    return out
end

function Store:read_index(server_key)
    local data, err = self:read_json(self:index_path(server_key))
    if type(data) ~= "table" or type(data.chapters) ~= "table" then
        return nil, err or "invalid index"
    end
    return to_array(data.chapters)
end

function Store:write_index(server_key, entries)
    entries = entries or {}
    table.sort(entries, entry_less)
    return self:write_json_atomic(self:index_path(server_key), {
        v = self.VERSION,
        updatedAt = self.clock(),
        chapters = entries,
    })
end

function Store:upsert_index_entry(server_key, entry)
    if type(entry) ~= "table" or not entry.chapterId then return nil, "invalid entry" end
    local entries = self:read_index(server_key) or self:rebuild_index(server_key)
    local replaced = false
    for i, existing in ipairs(entries) do
        if existing.chapterId == entry.chapterId then
            entries[i] = entry
            replaced = true
            break
        end
    end
    if not replaced then entries[#entries + 1] = entry end
    return self:write_index(server_key, entries)
end

function Store:remove_index_chapter(server_key, series_id, chapter_id)
    local entries = self:read_index(server_key)
    if not entries then return true end
    local kept = {}
    for _, e in ipairs(entries) do
        if not (e.chapterId == chapter_id and (series_id == nil or e.seriesId == series_id)) then
            kept[#kept + 1] = e
        end
    end
    return self:write_index(server_key, kept)
end

function Store:rebuild_index(server_key)
    -- stale flags are the only non-derivable field: preserve them across rebuilds.
    local stale = {}
    local old = self:read_index(server_key)
    if old then
        for _, e in ipairs(old) do
            if e.stale then stale[e.chapterId] = true end
        end
    end

    local entries = {}
    local root = self:server_root(server_key)
    for _, series_name in ipairs(list_dir(root)) do
        if series_name:sub(1, 1) ~= "." then
            local sdir = root .. "/" .. series_name
            if is_dir(sdir) then
                for _, chapter_name in ipairs(list_dir(sdir)) do
                    local cdir = sdir .. "/" .. chapter_name
                    if is_dir(cdir) then
                        local meta = self:read_json(cdir .. "/meta.json")
                        if type(meta) == "table" then
                            entries[#entries + 1] = meta_to_index_entry(meta, stale[meta.chapterId])
                        end
                    end
                end
            end
        end
    end
    table.sort(entries, entry_less)
    self:write_index(server_key, entries)
    return entries
end

function Store:load_index_or_rebuild(server_key)
    local entries = self:read_index(server_key)
    if entries then return entries end
    return self:rebuild_index(server_key)
end

function Store:set_stale(server_key, series_id, chapter_id, stale)
    local entries = self:read_index(server_key)
    if not entries then return false end
    local found = false
    for _, e in ipairs(entries) do
        if e.chapterId == chapter_id and e.seriesId == series_id then
            e.stale = stale and true or false
            found = true
            break
        end
    end
    if not found then return false end
    self:write_index(server_key, entries)
    return true
end

-- Bulk stale update: flags = { [chapterId] = true|false }. Unknown chapters are
-- ignored (only cached chapters can be stale).
function Store:update_stale(server_key, flags)
    if type(flags) ~= "table" or not next(flags) then return false end
    local entries = self:read_index(server_key) or self:rebuild_index(server_key)
    local changed = false
    for _, e in ipairs(entries) do
        local flag = flags[e.chapterId]
        if flag ~= nil and e.stale ~= (flag and true or false) then
            e.stale = flag and true or false
            changed = true
        end
    end
    if changed then self:write_index(server_key, entries) end
    return changed
end

function Store:is_stale(server_key, series_id, chapter_id)
    local entries = self:read_index(server_key)
    if not entries then return false end
    for _, e in ipairs(entries) do
        if e.chapterId == chapter_id and (series_id == nil or e.seriesId == series_id) then
            return e.stale == true
        end
    end
    return false
end

-- ---- delete / usage ------------------------------------------------------

function Store:dir_usage(path)
    return size_of_tree(path)
end

function Store:delete_chapter(server_key, series_id, chapter_id)
    local freed = 0
    local cdir = self:chapter_dir(server_key, series_id, chapter_id)
    freed = freed + size_of_tree(cdir)
    remove_tree(cdir)
    local part = self:part_path(server_key, chapter_id)
    freed = freed + self:file_size(part)
    os.remove(part)
    self:remove_index_chapter(server_key, series_id, chapter_id)
    return freed
end

function Store:delete_series(server_key, series_id)
    local freed = 0
    local count = 0
    local sdir = self:series_dir(server_key, series_id)
    for _, name in ipairs(list_dir(sdir)) do
        local path = sdir .. "/" .. name
        if is_dir(path) then
            freed = freed + size_of_tree(path)
            count = count + 1
            os.remove(self:part_path(server_key, name))
        elseif name:match("^cover%.") then
            freed = freed + self:file_size(path)
        end
    end
    remove_tree(sdir)

    local entries = self:read_index(server_key) or {}
    local kept = {}
    for _, e in ipairs(entries) do
        if e.seriesId ~= series_id then kept[#kept + 1] = e end
    end
    self:write_index(server_key, kept)
    return freed, count
end

function Store:delete_server(server_key)
    local freed, count = 0, 0
    local usage = self:server_usage(server_key)
    freed = usage.used
    count = usage.chapters
    remove_tree(self:server_root(server_key))
    return freed, count
end

function Store:delete_all()
    local freed, count = 0, 0
    for _, key in ipairs(self:list_server_keys()) do
        local u = self:server_usage(key)
        freed = freed + u.used
        count = count + u.chapters
    end
    for _, key in ipairs(self:list_server_keys()) do
        remove_tree(self:server_root(key))
    end
    return freed, count
end

function Store:delete_chapters(list)
    local freed, count = 0, 0
    for _, item in ipairs(list or {}) do
        freed = freed + self:delete_chapter(item.serverKey, item.seriesId, item.chapterId)
        count = count + 1
    end
    return freed, count
end

function Store:server_usage(server_key)
    local used, chapters = 0, 0
    local root = self:server_root(server_key)
    for _, series_name in ipairs(list_dir(root)) do
        local sdir = root .. "/" .. series_name
        if series_name:sub(1, 1) ~= "." and is_dir(sdir) then
            for _, name in ipairs(list_dir(sdir)) do
                local path = sdir .. "/" .. name
                if is_dir(path) then
                    if self:exists(path .. "/meta.json") then chapters = chapters + 1 end
                    used = used + size_of_tree(path)
                elseif name:match("^cover%.") then
                    used = used + self:file_size(path)
                end
            end
        end
    end
    local incoming = self:incoming_dir(server_key)
    for _, name in ipairs(list_dir(incoming)) do
        used = used + self:file_size(incoming .. "/" .. name)
    end
    return { used = used, chapters = chapters }
end

function Store:total_usage()
    local used, chapters = 0, 0
    for _, key in ipairs(self:list_server_keys()) do
        local u = self:server_usage(key)
        used = used + u.used
        chapters = chapters + u.chapters
    end
    return { used = used, chapters = chapters }
end

function Store:free_bytes()
    local ok, util = pcall(require, "ffi/util")
    if not ok or not util then return nil end
    local function avail_of(path)
        local pok, _, _, avail = pcall(util.df, path)
        if not pok then return nil end
        return avail
    end
    local avail = avail_of(self:cache_root())
    if avail == nil then
        -- The cache root is created by the first download; before that,
        -- statvfs() on it fails. The data dir is on the same filesystem.
        avail = avail_of(self:_data_dir())
    end
    return avail
end

function Store:list_server_keys()
    local keys = {}
    for _, name in ipairs(list_dir(self:cache_root())) do
        if name:sub(1, 1) ~= "." and is_dir(self:cache_root() .. "/" .. name) then
            keys[#keys + 1] = name
        end
    end
    return keys
end

function Store:list_series_ids(server_key)
    local ids = {}
    for _, name in ipairs(list_dir(self:server_root(server_key))) do
        if name:sub(1, 1) ~= "." and is_dir(self:series_dir(server_key, name)) then
            ids[#ids + 1] = tonumber(name) or name
        end
    end
    return ids
end

function Store:list_chapter_ids(server_key, series_id)
    local ids = {}
    for _, name in ipairs(list_dir(self:series_dir(server_key, series_id))) do
        if is_dir(self:chapter_dir(server_key, series_id, name)) then
            ids[#ids + 1] = tonumber(name) or name
        end
    end
    return ids
end

-- ---- server keys ---------------------------------------------------------

function Store:generate_server_key(existing_keys)
    local sha2 = require("ffi/sha2")
    local seen = {}
    for _, key in ipairs(existing_keys or {}) do seen[key] = true end
    local seed = tostring(os.time()) .. tostring(os.clock()) .. tostring({}) .. tostring(math.random())
    for attempt = 1, 100 do
        local digest = sha2.md5(seed .. tostring(attempt))
        local key = digest:sub(1, 8):lower()
        if not seen[key] then return key end
    end
    -- Extremely unlikely; still return a stable-shaped key.
    return sha2.md5(seed .. "fallback"):sub(1, 8):lower()
end

-- Read-only variant: returns the stored key or nil, never writes settings.
function Store:find_server_key(settings, server)
    if not settings or type(server) ~= "table" then return nil end
    local servers = settings:readSetting("servers", {}) or {}
    local wanted_url = server.base_url or server.url or server.kavita_url
    local wanted_name = server.name
    for _, s in ipairs(servers) do
        if type(s) == "table" and
            ((wanted_url and wanted_url ~= "" and (s.kavita_url == wanted_url or s.url == wanted_url))
                or (wanted_name and s.name == wanted_name)) then
            return s.key
        end
    end
    return nil
end

-- Resolve (or lazily create) the stable cache key of a configured server.
-- Matches the same way existing code decides "same server": url or name.
function Store:resolve_server_key(settings, server)
    if not settings or type(server) ~= "table" then return nil end
    local servers = settings:readSetting("servers", {}) or {}
    local wanted_url = server.base_url or server.url or server.kavita_url
    local wanted_name = server.name

    local entry
    for _, s in ipairs(servers) do
        if type(s) == "table" and
            ((wanted_url and wanted_url ~= "" and (s.kavita_url == wanted_url or s.url == wanted_url))
                or (wanted_name and s.name == wanted_name)) then
            entry = s
            break
        end
    end
    if not entry then return nil end

    if entry.key and entry.key ~= "" then
        return entry.key
    end

    local existing = {}
    for _, s in ipairs(servers) do
        if type(s) == "table" and s.key then existing[#existing + 1] = s.key end
    end
    entry.key = self:generate_server_key(existing)
    settings:saveSetting("servers", servers)
    -- Persist immediately: a crash before KOReader's normal settings flush
    -- must not lose the only copy of the server configuration.
    pcall(function() settings:flush() end)
    logger.info("[kamare:cache] generated server key", entry.key, "for", tostring(entry.name))
    return entry.key
end

return Store
