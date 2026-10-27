--[[--
Offline reading journal.

Two structures, both local to the device:

  positions[serverKey:chapterId]  the exact PageNum that would be POSTed to
                                  Kavita (non-last page: physical-1; last page:
                                  physical), replayed on reconnect
  sessions[]                      real local start/end and page span; never
                                  pushed to Kavita (its timestamps cannot be
                                  backdated, see ticket 01)

Disk writes are debounced 20 s idle, with forced flushes on close, chapter
switch, suspend and every 20 page advances. Network sync is a separate knob
and lives in `sync()`: per position it reads the remote progress first and only
pushes when local is strictly ahead (monotonic rule).

The journal is self-contained: sync never re-reads meta.json, so deleting a
cached chapter does not lose its pending progress.
--]]

local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local logger = require("logger")

local Journal = {}
Journal.__index = Journal

Journal.VERSION = 1
Journal.IDLE_FLUSH_SECONDS = 20
Journal.PAGES_FLUSH_THRESHOLD = 20
Journal.MAX_POSITIONS = 300
Journal.MAX_SESSIONS = 300
Journal.SESSION_MAX_AGE = 90 * 24 * 3600
Journal.PUSHED_KEEP_SECONDS = 7 * 24 * 3600

local function now()
    return os.time()
end

local function to_array(tbl)
    local out = {}
    if type(tbl) == "table" then
        for _, v in ipairs(tbl) do out[#out + 1] = v end
    end
    return out
end

local function ensure_dir(path)
    if not path or path == "" then return nil end
    local acc = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        if acc == "/" then acc = "/" .. part
        elseif acc == "" then acc = part
        else acc = acc .. "/" .. part end
        if lfs.attributes(acc, "mode") == nil then
            local ok, err = lfs.mkdir(acc)
            if not ok then return nil, err end
        end
    end
    return true
end

function Journal:new(opts)
    opts = opts or {}
    local o = setmetatable({
        settings_dir = opts.settings_dir,
        scheduler = opts.scheduler,
        clock = opts.clock or now,
        limits = opts.limits or {},
        positions = {},
        sessions = {},
        dirty = false,
        _pages_since_flush = 0,
        _flush_task = nil,
        _open_sessions = {},
    }, self)
    return o
end

function Journal:_settings_dir()
    if self.settings_dir then return self.settings_dir end
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir()
end

function Journal:path()
    return self:_settings_dir() .. "/kamare-journal.json"
end

function Journal:_key_position(pos)
    return tostring(pos.serverKey) .. ":" .. tostring(pos.chapterId)
end

function Journal:_key(server_key, chapter_id)
    return tostring(server_key) .. ":" .. tostring(chapter_id)
end

function Journal:load()
    self.positions = {}
    self.sessions = {}
    self.dirty = false
    local path = self:path()

    local f = io.open(path, "rb")
    if not f then return true end
    local data = f:read("*a")
    f:close()

    local ok, decoded = pcall(rapidjson.decode, data)
    if not ok or type(decoded) ~= "table" then
        local bad = path .. ".corrupt." .. tostring(self.clock())
        os.rename(path, bad)
        logger.warn("[kamare:journal] corrupt journal moved to", bad)
        return true
    end

    if type(decoded.positions) == "table" then
        for key, pos in pairs(decoded.positions) do
            if type(pos) == "table" and pos.chapterId and pos.serverKey then
                self.positions[key] = pos
            end
        end
    end
    self.sessions = to_array(decoded.sessions)
    self:evict()
    return true
end

function Journal:_write()
    local payload = {
        v = self.VERSION,
        positions = self.positions,
        sessions = self.sessions,
        meta = { updatedAt = self.clock() },
    }
    local ok, encoded = pcall(rapidjson.encode, payload)
    if not ok or type(encoded) ~= "string" then
        logger.warn("[kamare:journal] encode failed", tostring(encoded))
        return nil, "encode failed"
    end
    local path = self:path()
    local dir_ok, derr = ensure_dir(path:match("^(.*)/[^/]+$"))
    if not dir_ok then return nil, derr end
    local tmp = path .. ".tmp"
    local fh = io.open(tmp, "wb")
    if not fh then return nil, "open tmp failed" end
    local wok = fh:write(encoded)
    fh:close()
    if not wok then os.remove(tmp); return nil, "write failed" end
    local rok, rerr = os.rename(tmp, path)
    if not rok then os.remove(tmp); return nil, rerr end
    self.dirty = false
    self._pages_since_flush = 0
    return true
end

function Journal:flush()
    if self._flush_task then
        pcall(function() self.scheduler:unschedule(self._flush_task) end)
        self._flush_task = nil
    end
    return self:_write()
end

function Journal:force_flush()
    return self:flush()
end

function Journal:_mark_dirty(force)
    self.dirty = true
    if force or not self.scheduler then
        return self:flush()
    end
    if self._flush_task then
        pcall(function() self.scheduler:unschedule(self._flush_task) end)
    end
    self._flush_task = function()
        self._flush_task = nil
        self:flush()
    end
    self.scheduler:scheduleIn(self.IDLE_FLUSH_SECONDS, self._flush_task)
    return true
end

function Journal:_copy_identity(entry)
    return {
        serverKey = entry.serverKey,
        libraryId = entry.libraryId,
        seriesId = entry.seriesId,
        volumeId = entry.volumeId,
        chapterId = entry.chapterId,
        seriesName = entry.seriesName,
        chapterTitle = entry.chapterTitle,
    }
end

function Journal:get_position(server_key, chapter_id)
    return self.positions[self:_key(server_key, chapter_id)]
end

--- Record the position that should be POSTed. `entry` supplies identity.
--- opts = { source = "online"|"offline", pushed = bool, force = bool }
function Journal:set_position(entry, page_num, opts)
    opts = opts or {}
    if type(entry) ~= "table" or not entry.serverKey or not entry.chapterId or type(page_num) ~= "number" then
        return nil
    end
    local key = self:_key(entry.serverKey, entry.chapterId)
    local pos = self.positions[key]
    local advanced = not pos or pos.pageNum ~= page_num

    if not pos then
        pos = self:_copy_identity(entry)
        pos.pageNum = page_num
        pos.ts = self.clock()
        pos.status = "pending"
        self.positions[key] = pos
    else
        if pos.pageNum ~= page_num then
            pos.pageNum = page_num
            pos.ts = self.clock()
            if pos.status == "pushed" or pos.status == "superseded" then
                pos.status = "pending"
            end
        end
        -- Refresh display names in case the series was renamed locally.
        pos.seriesName = entry.seriesName or pos.seriesName
        pos.chapterTitle = entry.chapterTitle or pos.chapterTitle
    end

    if opts.pushed then pos.status = "pushed" end
    if opts.source == "offline" and pos.status ~= "pushed" then pos.status = "pending" end

    if advanced then
        self._pages_since_flush = self._pages_since_flush + 1
    end
    local force = opts.force or self._pages_since_flush >= self.PAGES_FLUSH_THRESHOLD
    self:_mark_dirty(force)
    return pos
end

local function find_position(self, server_key, chapter_id)
    return self.positions[self:_key(server_key, chapter_id)]
end

function Journal:mark_pushed(server_key, chapter_id)
    local pos = find_position(self, server_key, chapter_id)
    if not pos then return false end
    pos.status = "pushed"
    pos.ts = pos.ts or self.clock()
    self:_mark_dirty(false)
    return true
end

function Journal:mark_failed(server_key, chapter_id)
    local pos = find_position(self, server_key, chapter_id)
    if not pos then return false end
    pos.status = "failed"
    self:_mark_dirty(false)
    return true
end

function Journal:mark_superseded(server_key, chapter_id)
    local pos = find_position(self, server_key, chapter_id)
    if not pos then return false end
    pos.status = "superseded"
    self:_mark_dirty(false)
    return true
end

function Journal:pending_count()
    local n = 0
    for _, pos in pairs(self.positions) do
        if pos.status == "pending" or pos.status == "failed" then n = n + 1 end
    end
    return n
end

function Journal:all_positions()
    local out = {}
    for _, pos in pairs(self.positions) do out[#out + 1] = pos end
    table.sort(out, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
    return out
end

function Journal:get_sessions()
    return self.sessions
end

function Journal:session_seconds()
    local total = 0
    for _, s in ipairs(self.sessions) do
        local a = tonumber(s.startTs) or 0
        local b = tonumber(s.endTs) or a
        if b > a then total = total + (b - a) end
    end
    return total
end

-- ---- sessions ------------------------------------------------------------

function Journal:session_start(entry, page_num, opts)
    opts = opts or {}
    if opts.source ~= "offline" then return nil end
    local key = self:_key(entry.serverKey, entry.chapterId)
    self:session_end(entry)
    local session = self:_copy_identity(entry)
    session.startTs = self.clock()
    session.endTs = session.startTs
    session.startPage = page_num or 1
    session.endPage = page_num or 1
    self._open_sessions[key] = session
    return session
end

function Journal:session_update(entry, page_num)
    local key = self:_key(entry.serverKey, entry.chapterId)
    local session = self._open_sessions[key]
    if not session then return nil end
    session.endTs = self.clock()
    session.endPage = page_num or session.endPage
    self.dirty = true
    return session
end

function Journal:session_end(entry)
    local key = self:_key(entry.serverKey, entry.chapterId)
    local session = self._open_sessions[key]
    if not session then return nil end
    self._open_sessions[key] = nil
    session.endTs = self.clock()
    session.pages = math.max(0, (tonumber(session.endPage) or 0) - (tonumber(session.startPage) or 0) + 1)
    self.sessions[#self.sessions + 1] = session
    self.dirty = true
    self:_mark_dirty(false)
    return session
end

-- Direct session insertion, mostly for tests/import.
function Journal:touch_session(entry, start_page, end_page, opts)
    opts = opts or {}
    local session = self:_copy_identity(entry)
    session.startTs = opts.startTs or self.clock()
    session.endTs = opts.endTs or self.clock()
    session.startPage = start_page or 1
    session.endPage = end_page or start_page or 1
    session.pages = math.max(0, (tonumber(session.endPage) or 0) - (tonumber(session.startPage) or 0) + 1)
    self.sessions[#self.sessions + 1] = session
    self.dirty = true
    self:_mark_dirty(opts.force or false)
    return session
end

-- ---- eviction ------------------------------------------------------------

function Journal:evict()
    local max_positions = self.limits.positions or self.MAX_POSITIONS
    local max_sessions = self.limits.sessions or self.MAX_SESSIONS
    local keep = self.PUSHED_KEEP_SECONDS
    local t = self.clock()

    -- pushed positions: drop after 7 days, then cap by oldest pushed.
    local pushed = {}
    for key, pos in pairs(self.positions) do
        if pos.status == "pushed" then
            if pos.ts and t - pos.ts > keep then
                self.positions[key] = nil
            else
                pushed[#pushed + 1] = key
            end
        end
    end

    local count = 0
    for _ in pairs(self.positions) do count = count + 1 end
    if count > max_positions then
        table.sort(pushed, function(a, b)
            return (self.positions[a].ts or 0) < (self.positions[b].ts or 0)
        end)
        for _, key in ipairs(pushed) do
            if count <= max_positions then break end
            self.positions[key] = nil
            count = count - 1
        end
    end

    -- sessions: 90 days, then cap by oldest.
    local kept = {}
    for _, s in ipairs(self.sessions) do
        if not s.endTs or t - s.endTs <= self.SESSION_MAX_AGE then
            kept[#kept + 1] = s
        end
    end
    while #kept > max_sessions do table.remove(kept, 1) end
    self.sessions = kept
    self.dirty = true
end

-- ---- sync ----------------------------------------------------------------

function Journal:_session_end_for(pos)
    for _, s in ipairs(self.sessions) do
        if s.serverKey == pos.serverKey and s.chapterId == pos.chapterId then
            return s.endTs or s.startTs or 0
        end
    end
    return pos.ts or 0
end

--- Push pending/failed positions to Kavita using the monotonic rule.
--- opts = { is_current = function(pos) -> bool,
---          prompt_current = function(pos, remote) -> "local"|"remote" }
--- returns { pushed, superseded, failed, skipped, conflict }
function Journal:sync(client, opts)
    opts = opts or {}
    local summary = { pushed = 0, superseded = 0, failed = 0, skipped = 0, conflict = 0 }
    if not client then return summary end

    local pending = {}
    for _, pos in pairs(self.positions) do
        if pos.status == "pending" or pos.status == "failed" then
            pending[#pending + 1] = pos
        end
    end
    table.sort(pending, function(a, b)
        return self:_session_end_for(a) < self:_session_end_for(b)
    end)

    for _, pos in ipairs(pending) do
        local pok, remote, code = pcall(client.getReaderProgress, client, pos.chapterId)
        if not pok then remote, code = nil, -1 end
        if type(remote) ~= "table" or (type(code) == "number" and (code < 200 or code >= 300)) then
            summary.skipped = summary.skipped + 1
            -- Server unreachable: do not hammer it for the rest of the batch.
            if code == nil or code == -1 or code == "timeout" then break end
        else
            local remote_page = tonumber(remote.pageNum) or 0
            local local_page = tonumber(pos.pageNum) or 0
            local push = local_page > remote_page

            if not push and local_page < remote_page
                and opts.force_current_chapter and opts.force_current_chapter == pos.chapterId then
                push = true
            elseif not push and local_page < remote_page
                and opts.is_current and opts.is_current(pos) and opts.prompt_current then
                local choice = opts.prompt_current(pos, remote)
                summary.conflict = summary.conflict + 1
                if choice == "local" then push = true end
            end

            if push then
                local payload = {
                    volumeId = pos.volumeId,
                    chapterId = pos.chapterId,
                    pageNum = local_page,
                    seriesId = pos.seriesId,
                    libraryId = pos.libraryId,
                }
                local post_ok, pcode = pcall(client.postReaderProgress, client, payload)
                if not post_ok then pcode = -1 end
                if pcode == 200 or pcode == 204 then
                    pos.status = "pushed"
                    summary.pushed = summary.pushed + 1
                else
                    pos.status = "failed"
                    summary.failed = summary.failed + 1
                end
            else
                pos.status = "superseded"
                summary.superseded = summary.superseded + 1
            end
        end
    end

    self:evict()
    self:flush()
    return summary
end

return Journal
