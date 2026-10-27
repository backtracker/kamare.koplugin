--[[--
Serial chapter download queue.

One chapter at a time (eMMC + single link: parallel downloads only make each
other slower and double the peak disk usage). Each chapter gets up to three
attempts with 2/8/20 s backoff, always resuming from the existing `.part` with
a Range request. Three consecutive chapter failures pause the whole batch.

The queue never decides "cached": only `meta.json` does (see
kamarecachestore). A queue entry is at most "in progress".
--]]

local logger = require("logger")
local _ = require("gettext")
local Store = require("kamarecachestore")

local Queue = {}
Queue.__index = Queue

Queue.PEAK_FACTOR = 2.05
Queue.LOW_WATER_BYTES = 500 * 1024 * 1024
Queue.RETRY_BACKOFF = { 2, 8, 20 }
Queue.MAX_ATTEMPTS = 3
Queue.MAX_CONSECUTIVE_FAILURES = 3

local function now()
    return os.time()
end

local function looks_like_image(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(16) or ""
    f:close()
    return head:sub(1, 2) == "\255\216"          -- jpeg
        or head:sub(1, 8) == "\137PNG\r\n\26\n" -- png
        or head:sub(1, 4) == "GIF8"                -- gif
        or (head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP")
        or head:sub(5, 8) == "ftyp"                -- avif/heif
end

local function safe_call(ui, name, ...)
    if type(ui) ~= "table" or type(ui[name]) ~= "function" then return end
    local ok, err = pcall(ui[name], ...)
    if not ok then logger.warn("[kamare:queue] ui hook failed:", name, err) end
end

local function chunk_key(server_key, chapter_id)
    return tostring(server_key) .. ":" .. tostring(chapter_id)
end

function Queue:new(opts)
    opts = opts or {}
    local o = setmetatable({
        store = opts.store or Store,
        settings = opts.settings,
        client = opts.client,
        scheduler = opts.scheduler,
        network = opts.network,
        ui = opts.ui or {},
        archive = opts.archive,
        fetch = opts.fetch,
        entries = {},
        state = "idle",
        paused = true, -- never auto-start on boot
        pause_reason = nil,
        current = nil,
        consecutive_failures = 0,
        completed_bytes = 0,
        _standby = false,
        _scheduled = false,
        _handle = nil,
        clock = opts.clock or now,
    }, self)
    return o
end

function Queue:_scheduler()
    if not self.scheduler then self.scheduler = require("ui/uimanager") end
    return self.scheduler
end

function Queue:_network()
    if self.network == nil then
        local ok, mgr = pcall(require, "ui/network/manager")
        self.network = ok and mgr or false
    end
    return self.network or nil
end

function Queue:_archive()
    if not self.archive then self.archive = require("kamarecachearchive") end
    return self.archive
end

function Queue:_fetch()
    if not self.fetch then self.fetch = require("kamareasyncfetch") end
    return self.fetch
end

function Queue:_schedule(delay)
    if self._scheduled then return end
    self._scheduled = true
    self:_scheduler():scheduleIn(delay or 0, function()
        self._scheduled = false
        self:_step()
    end)
end

function Queue:_standby_on()
    if self._standby then return end
    self._standby = true
    safe_call(self.ui, "prevent_standby")
end

function Queue:_standby_off()
    if not self._standby then return end
    self._standby = false
    safe_call(self.ui, "allow_standby")
end

function Queue:_changed()
    safe_call(self.ui, "on_state_change", self:status())
end

-- ---- persistence ---------------------------------------------------------

function Queue:load()
    self.entries = {}
    if not self.settings then return true end
    local saved = self.settings:readSetting("download_queue", {})
    if type(saved) ~= "table" then return true end
    for _, e in ipairs(saved) do
        if type(e) == "table" and e.chapterId and e.serverKey then
            e.state = e.state or "queued"
            e.attempts = tonumber(e.attempts) or 0
            self.entries[#self.entries + 1] = e
        end
    end
    -- A restored queue is always paused: starting a 300 MB download at boot is
    -- never what the user asked for.
    self.paused = true
    self.pause_reason = #self.entries > 0 and "restored" or nil
    self.state = #self.entries > 0 and "paused" or "idle"
    return true
end

function Queue:save()
    if not self.settings then return end
    self.settings:saveSetting("download_queue", self.entries)
    pcall(function() self.settings:flush() end)
end

function Queue:_wifi_only()
    if not self.settings then return true end
    local v = self.settings:readSetting("download_wifi_only", true)
    return v ~= false
end

-- ---- enqueue / control ---------------------------------------------------

function Queue:_hydrate(entry)
    if entry.archiveBytes and entry.pages and entry.volumeId and entry.libraryId
        and entry.seriesId and entry.files ~= nil then
        return true
    end
    if not self.client or not self.client.getChapterById then return nil, "missing chapter metadata" end
    local chapter = self.client:getChapterById(entry.chapterId)
    if type(chapter) ~= "table" then return nil, "chapter not found" end

    entry.pages = entry.pages or chapter.pages
    entry.volumeId = entry.volumeId or chapter.volumeId
    entry.seriesId = entry.seriesId or chapter.seriesId
    entry.libraryId = entry.libraryId or chapter.libraryId
    entry.chapterTitle = entry.chapterTitle or chapter.titleName or chapter.title
    entry.chapterNumber = entry.chapterNumber or chapter.number
    entry.order = entry.order or chapter.order
    entry.pagesReadSnapshot = entry.pagesReadSnapshot or chapter.pagesRead
    entry.files = entry.files or chapter.files

    local bytes = 0
    for _, f in ipairs(entry.files or {}) do
        bytes = bytes + (tonumber(f.bytes) or 0)
    end
    entry.archiveBytes = entry.archiveBytes or (bytes > 0 and bytes or nil)
    if entry.files and entry.files[1] then
        entry.koreaderHash = entry.koreaderHash or entry.files[1].koreaderHash
        local name = entry.files[1].filePath or entry.files[1].path or ""
        local ext = name:match("%.([%w]+)$")
        entry.archiveExt = entry.archiveExt or (ext and ext:lower() or nil)
    end
    if not entry.archiveBytes then return nil, "cannot determine chapter size" end
    return true
end

function Queue:enqueue(entries, opts)
    opts = opts or {}
    if type(entries) ~= "table" or #entries == 0 then return nil, _("Nothing to download") end

    local accepted, seen, total = {}, {}, 0
    for _, raw in ipairs(entries or {}) do
        if type(raw) == "table" and raw.chapterId and raw.serverKey then
            local key = chunk_key(raw.serverKey, raw.chapterId)
            local duplicate = seen[key] or self:contains(raw.serverKey, raw.chapterId)
                or self.store:has_meta(raw.serverKey, raw.seriesId, raw.chapterId)
            if not duplicate then
                local entry = {}
                for k, v in pairs(raw) do entry[k] = v end
                local ok, err = self:_hydrate(entry)
                if ok then
                    entry.state = "queued"
                    entry.attempts = 0
                    entry.queuedAt = self.clock()
                    entry.lastError = nil
                    seen[key] = true
                    accepted[#accepted + 1] = entry
                    total = total + (entry.archiveBytes or 0) * self.PEAK_FACTOR
                else
                    logger.warn("[kamare:queue] skip chapter", raw.chapterId, err)
                end
            end
        end
    end

    if #accepted == 0 then return nil, _("Already cached or queued") end

    -- Optional absolute cap (default off): quota applies to the whole cache.
    if self.settings then
        local limit_mb = tonumber(self.settings:readSetting("cache_limit_mb", 0)) or 0
        if limit_mb > 0 then
            local limit = limit_mb * 1024 * 1024
            local used = self.store:total_usage().used
            if used + total > limit then
                return nil, string.format(_("Cache limit reached: %s of %s used"),
                    string.format("%.0f MB", used / (1024 * 1024)),
                    string.format("%.0f MB", limit / (1024 * 1024)))
            end
        end
    end

    local available = self.store:free_bytes()
    if available and total > available then
        return nil, string.format(_("Not enough space: need %.0f MB, %.0f MB available"),
            total / (1024 * 1024), available / (1024 * 1024))
    end
    if available and available < self.LOW_WATER_BYTES then
        return nil, _("Not enough free space to download")
    end

    if opts.confirm then
        local ok, confirmed = pcall(opts.confirm, {
            chapters = #accepted,
            bytes = total,
            available = available,
        })
        if not ok or not confirmed then return nil, _("Download cancelled") end
    end

    local was_empty = #self.entries == 0
    for _, entry in ipairs(accepted) do
        self.entries[#self.entries + 1] = entry
    end
    if was_empty then self.completed_bytes = 0 end
    self.paused = false
    self.pause_reason = nil
    self:save()
    self:_changed()
    self:resume()
    return true, nil, { chapters = #accepted, bytes = total, available = available }
end

function Queue:contains(server_key, chapter_id)
    for _, e in ipairs(self.entries) do
        if e.serverKey == server_key and e.chapterId == chapter_id then return true end
    end
    return false
end

function Queue:is_paused()
    return self.paused
end

function Queue:pause(reason)
    self.paused = true
    self.pause_reason = reason
    self.state = "paused"
    if self._handle then
        pcall(function() self._handle.cancel() end)
        self._handle = nil
    end
    if self.current then
        self.current.state = "queued"
        self.current = nil
    end
    self:_standby_off()
    self:save()
    self:_changed()
end

function Queue:resume()
    if #self.entries == 0 then
        self.paused = true
        self.state = "idle"
        self:_changed()
        return
    end
    self.paused = false
    self.pause_reason = nil
    self:_schedule(0)
end

function Queue:_entry_index(server_key, chapter_id)
    for i, e in ipairs(self.entries) do
        if e.serverKey == server_key and e.chapterId == chapter_id then return i, e end
    end
end

function Queue:cancel(server_key, chapter_id)
    local i, entry = self:_entry_index(server_key, chapter_id)
    if not i then return false end
    if self.current == entry and self._handle then
        pcall(function() self._handle.cancel() end)
        self._handle = nil
        self.current = nil
        self:_standby_off()
    end
    table.remove(self.entries, i)
    self:save()
    self:_changed()
    return true
end

function Queue:abort(server_key, chapter_id)
    local i, entry = self:_entry_index(server_key, chapter_id)
    if not i then return false end
    self:cancel(server_key, chapter_id)
    os.remove(self.store:part_path(server_key, chapter_id))
    self:_changed()
    return true
end

function Queue:remove(server_key, chapter_id)
    return self:cancel(server_key, chapter_id)
end

function Queue:retry(server_key, chapter_id)
    local _, entry = self:_entry_index(server_key, chapter_id)
    if not entry then return false end
    entry.state = "queued"
    entry.attempts = 0
    entry.lastError = nil
    entry.queuedAt = self.clock()
    self.consecutive_failures = 0
    self:_changed()
    self:resume()
    return true
end

function Queue:status()
    local total, done, index = 0, 0, 0
    for i, e in ipairs(self.entries) do
        total = total + (tonumber(e.archiveBytes) or 0)
        done = done + self.store:file_size(self.store:part_path(e.serverKey, e.chapterId))
        if self.current == e then index = i end
    end
    total = total + self.completed_bytes
    done = done + self.completed_bytes
    return {
        state = self.state,
        current = self.current,
        index = index,
        total = #self.entries,
        bytes_done = done,
        bytes_total = total,
        pending_count = #self.entries,
        consecutive_failures = self.consecutive_failures,
        pause_reason = self.pause_reason,
        last_error = self.current and self.current.lastError or nil,
    }
end

function Queue:progress_fraction(entry)
    if not entry or not entry.archiveBytes or entry.archiveBytes <= 0 then return 0 end
    local size = self.store:file_size(self.store:part_path(entry.serverKey, entry.chapterId))
    return math.max(0, math.min(1, size / entry.archiveBytes))
end

-- ---- pump ----------------------------------------------------------------

function Queue:_network_ok()
    local net = self:_network()
    if not net then return true end
    if net.isOnline then
        local ok, online = pcall(net.isOnline, net)
        if ok and online == false then return nil, "offline" end
    end
    if self:_wifi_only() and net.isWifiOn then
        local ok, wifi = pcall(net.isWifiOn, net)
        if ok and wifi == false then return nil, "wifi" end
    end
    return true
end

function Queue:_next_entry()
    for _, e in ipairs(self.entries) do
        if e.state ~= "failed" then return e end
    end
end

function Queue:_step()
    if self.paused then
        self.state = #self.entries > 0 and "paused" or "idle"
        self:_standby_off()
        return
    end

    local entry = self:_next_entry()
    if not entry then
        self.state = "idle"
        self.current = nil
        self.completed_bytes = 0
        self:_standby_off()
        self:save()
        self:_changed()
        return
    end
    self.current = entry

    local net_ok, reason = self:_network_ok()
    if not net_ok then
        self:pause(reason)
        return
    end

    local free = self.store:free_bytes()
    local need = (entry.archiveBytes or 0) * self.PEAK_FACTOR
    if free and (free < self.LOW_WATER_BYTES or free < need) then
        self:pause("low_space")
        return
    end

    if self.store:has_meta(entry.serverKey, entry.seriesId, entry.chapterId) then
        self:_finish_entry(entry)
        self:_schedule(0)
        return
    end

    local ok, err = self:_hydrate(entry)
    if not ok then
        self:_fail_entry(entry, err)
        return
    end

    free = self.store:free_bytes()
    need = (entry.archiveBytes or 0) * self.PEAK_FACTOR
    if free and (free < self.LOW_WATER_BYTES or free < need) then
        self:pause("low_space")
        return
    end

    self.state = "downloading"
    entry.state = "downloading"
    self:_standby_on()
    self:_changed()

    if self:_needs_per_page(entry) then
        self:_download_pages(entry)
    else
        self:_download_archive(entry)
    end
end

function Queue:_needs_per_page(entry)
    if entry.files and #entry.files > 1 then return true, "multi-file chapter" end
    local ext = entry.archiveExt
    if ext and not (ext == "cbz" or ext == "zip" or ext == "cbr" or ext == "cb7") then
        return true, "not an archive: " .. ext
    end
    return false
end

function Queue:_download_archive(entry)
    local url = entry.downloadUrl
    local headers = entry.downloadHeaders
    if not url then
        if not self.client or not self.client.buildChapterDownloadRequest then
            self:_fail_entry(entry, "no download endpoint")
            return
        end
        local req, err = self.client:buildChapterDownloadRequest(entry.chapterId)
        if not req then
            self:_fail_entry(entry, err)
            return
        end
        url, headers = req.url, req.headers
    end

    local part = self.store:part_path(entry.serverKey, entry.chapterId)
    self.store:ensure_dir(self.store:incoming_dir(entry.serverKey))
    local archive = self:_archive()
    local handle = archive.download_to_part({
        url = url,
        headers = headers,
        part_path = part,
        archive_bytes = entry.archiveBytes,
        store = self.store,
        scheduler = self.scheduler,
        pause_when = function()
            return self:_fetch().page_requests_inflight() > 0
        end,
    }, function(ok, err)
        if self.current ~= entry or self.paused then return end
        if not ok then
            if err == "range-unsupported" then
                local f = io.open(part, "wb")
                if f then f:close() end
                self:_fail_entry(entry, "range unsupported")
            elseif tostring(err):find("http 403", 1, true) then
                self:_fallback_per_page(entry, "download forbidden")
            else
                self:_fail_entry(entry, err)
            end
            return
        end
        self:_extract_archive(entry)
    end)
    self._handle = handle
end

function Queue:_dims_for(entry)
    if not self.client or not self.client.getFileDimensions then return nil, "no file dimensions" end
    local dims = self.client:getFileDimensions(entry.chapterId)
    if type(dims) ~= "table" or #dims == 0 then return nil, "no file dimensions" end
    local names, sizes = {}, {}
    for i, d in ipairs(dims) do
        names[i] = d.fileName
        sizes[i] = { tonumber(d.width) or 0, tonumber(d.height) or 0 }
    end
    return { raw = dims, names = names, dims = sizes }
end

function Queue:_extract_archive(entry)
    local part = self.store:part_path(entry.serverKey, entry.chapterId)
    self.store:ensure_dir(self.store:incoming_dir(entry.serverKey))
    local archive = self:_archive()
    if not archive.validate_magic(part) then
        self:_fallback_per_page(entry, "not an archive")
        return
    end

    local dimensions, derr = self:_dims_for(entry)
    if not dimensions then
        self:_fail_entry(entry, derr)
        return
    end

    self.state = "extracting"
    entry.state = "extracting"
    self:_changed()

    local dest = self.store:chapter_dir(entry.serverKey, entry.seriesId, entry.chapterId)
    local result, err = archive.extract_chapter({
        archive_path = part,
        dest_dir = dest,
        expected_pages = entry.pages,
        dims_names = dimensions.names,
    })
    if not result then
        -- Page order/count mismatch is almost always an archive shape we could
        -- not replicate; per-page always works.
        self:_fallback_per_page(entry, err)
        return
    end

    if self.current ~= entry then return end
    local exts = {}
    for _, item in ipairs(result.plan or {}) do
        exts[item.page] = archive.page_extension(item.path)
    end
    self:_write_chapter(entry, {
        source = "archive",
        pages = result.pages,
        pagesBytes = result.pagesBytes,
        dims = dimensions.dims,
        pageExts = exts,
        archiveBytes = entry.archiveBytes,
        archiveExt = entry.archiveExt,
        koreaderHash = entry.koreaderHash,
    })
end

function Queue:_fallback_per_page(entry, why)
    logger.info("[kamare:queue] falling back to per-page for", entry.chapterId, why)
    local part = self.store:part_path(entry.serverKey, entry.chapterId)
    os.remove(part)
    self:_download_pages(entry, why)
end

function Queue:_download_pages(entry, why)
    local dimensions, derr = self:_dims_for(entry)
    if not dimensions then
        self:_fail_entry(entry, derr or "no dimensions")
        return
    end
    local pages = entry.pages or #dimensions.dims
    if not pages or pages <= 0 then
        self:_fail_entry(entry, "no pages")
        return
    end

    local dest_dir = self.store:chapter_dir(entry.serverKey, entry.seriesId, entry.chapterId)
    self:_archive().clear_dir(dest_dir)
    self.store:ensure_dir(dest_dir)

    self.state = "downloading"
    entry.state = "downloading"
    self:_changed()

    local page = 1
    local total_bytes = 0
    local handle

    local function next_page()
        if self.current ~= entry or self.paused then return end
        if page > pages then
            local exts = {}
            for i = 1, pages do exts[i] = "jpg" end
            self:_write_chapter(entry, {
                source = "per-page",
                pages = pages,
                pagesBytes = total_bytes,
                dims = dimensions.dims,
                pageExts = exts,
                archiveBytes = entry.archiveBytes,
                archiveExt = entry.archiveExt,
                koreaderHash = entry.koreaderHash,
                note = why,
            })
            return
        end

        local req, err = self.client:buildImageRequestTable(entry.chapterId, page - 1)
        if not req then self:_fail_entry(entry, err); return end
        local AsyncFetch = self:_fetch()
        local dest = self.store:page_path(entry.serverKey, entry.seriesId, entry.chapterId, page, "jpg")
        handle = AsyncFetch.fetch(req, {
            sink_path = dest,
            priority = "page",
            scheduler = self.scheduler,
            total_timeout = 120,
        }, function(_, code, stats)
            if self.current ~= entry or self.paused then return end
            if code ~= 200 then
                self:_fail_entry(entry, "page " .. page .. " http " .. tostring(code))
                return
            end
            if not looks_like_image(dest) then
                self:_fail_entry(entry, "page " .. page .. " is not an image")
                return
            end
            total_bytes = total_bytes + ((stats and stats.bytes) or 0)
            page = page + 1
            next_page()
        end)
        self._handle = handle
    end

    next_page()
end

function Queue:_write_chapter(entry, data)
    if self.current ~= entry then return end
    local ext_map = {}
    for page, ext in pairs(data.pageExts or {}) do ext_map[page] = ext end

    local meta = {
        v = 1,
        serverKey = entry.serverKey,
        serverUrl = entry.serverUrl,
        libraryId = entry.libraryId,
        seriesId = entry.seriesId,
        seriesName = entry.seriesName,
        volumeId = entry.volumeId,
        volumeName = entry.volumeName,
        chapterId = entry.chapterId,
        chapterTitle = entry.chapterTitle,
        chapterNumber = entry.chapterNumber,
        order = entry.order,
        pages = data.pages,
        source = data.source,
        archiveBytes = data.archiveBytes,
        archiveExt = data.archiveExt,
        koreaderHash = data.koreaderHash,
        pagesBytes = data.pagesBytes,
        dims = data.dims,
        pageExts = ext_map,
        pagesReadSnapshot = entry.pagesReadSnapshot,
        fingerprint = string.format("%s:%s:%s", tostring(data.pages), tostring(data.archiveBytes),
            tostring(data.koreaderHash)),
        state = "complete",
        cachedAt = self.clock(),
    }

    local ok, err = self.store:write_meta(meta)
    if not ok then
        self:_fail_entry(entry, "meta write: " .. tostring(err))
        return
    end
    self.store:upsert_index_entry(entry.serverKey, {
        seriesId = entry.seriesId,
        seriesName = entry.seriesName,
        chapterId = entry.chapterId,
        chapterTitle = entry.chapterTitle,
        chapterNumber = entry.chapterNumber,
        order = entry.order,
        pages = data.pages,
        archiveBytes = data.archiveBytes,
        pagesBytes = data.pagesBytes,
        state = "complete",
        stale = false,
        cachedAt = self.clock(),
    })
    self:_ensure_series(entry)

    os.remove(self.store:part_path(entry.serverKey, entry.chapterId))
    self:_finish_entry(entry, meta)
end

function Queue:_ensure_series(entry)
    if not entry.seriesId then return end
    local series = self.store:read_series(entry.serverKey, entry.seriesId)
    if not series then
        series = {
            v = 1, seriesId = entry.seriesId,
            seriesName = entry.seriesName,
            libraryId = entry.libraryId,
            chapters = {},
        }
    end
    if type(series.chapters) ~= "table" then series.chapters = {} end

    -- Prefer a full chapter list supplied by the browser; otherwise make sure
    -- at least this chapter is present.
    if type(entry.seriesChapters) == "table" and #entry.seriesChapters > 0 then
        local list = {}
        for _, c in ipairs(entry.seriesChapters) do list[#list + 1] = c end
        series.chapters = list
    end
    local found = false
    for _, c in ipairs(series.chapters) do
        if c.id == entry.chapterId then
            c.pages = entry.pages
            c.bytes = entry.archiveBytes
            c.title = entry.chapterTitle
            found = true
        end
    end
    if not found then
        series.chapters[#series.chapters + 1] = {
            id = entry.chapterId, volumeId = entry.volumeId,
            number = entry.chapterNumber, order = entry.order,
            title = entry.chapterTitle, pages = entry.pages, bytes = entry.archiveBytes,
        }
    end
    self.store:write_series(entry.serverKey, series)

    if not self.store:exists(self.store:cover_path(entry.serverKey, entry.seriesId)) then
        local cover
        if self.client and self.client.getSeriesCover then
            local ok, bytes = pcall(self.client.getSeriesCover, self.client, entry.seriesId)
            if ok then cover = bytes end
        end
        if cover then self.store:write_cover(entry.serverKey, entry.seriesId, cover, "jpg") end
    end
end

function Queue:_finish_entry(entry, meta)
    self.completed_bytes = self.completed_bytes + (entry.archiveBytes or 0)
    self.consecutive_failures = 0
    if self.current == entry then self.current = nil end
    for i, e in ipairs(self.entries) do
        if e == entry then table.remove(self.entries, i); break end
    end
    self:_standby_off()
    self:save()
    safe_call(self.ui, "on_chapter_done", entry, meta)
    self:_changed()
    self:_schedule(0)
end

function Queue:_fail_entry(entry, err, opts)
    opts = opts or {}
    entry.lastError = tostring(err)
    entry.attempts = (entry.attempts or 0) + 1
    logger.warn("[kamare:queue] chapter", entry.chapterId, "attempt", entry.attempts, "failed:", err)

    if entry.attempts < self.MAX_ATTEMPTS then
        entry.state = "queued"
        local delay = self.RETRY_BACKOFF[entry.attempts] or self.RETRY_BACKOFF[#self.RETRY_BACKOFF]
        self:_standby_off()
        self.state = "queued"
        self:_changed()
        self:_schedule(delay)
        return
    end

    entry.state = "failed"
    self.consecutive_failures = self.consecutive_failures + 1
    self:_standby_off()
    if self.current == entry then self.current = nil end

    if self.consecutive_failures >= self.MAX_CONSECUTIVE_FAILURES then
        self:pause("network")
        return
    end

    self:save()
    self:_changed()
    self:_schedule(0)
end

return Queue
