local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local KavitaClient = require("kavitaclient")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local KamareImageViewer = require("kamareimageviewer")
local _ = require("gettext")
local Utils = require("kamareutils")
local T = ffiUtil.template

-- Progress indicator for read status
local function progress_icon(read, total)
    if type(read) ~= "number" or type(total) ~= "number" or total <= 0 then return nil end
    if read <= 0 then return "○" end -- 0%
    local r = read / total
    if r >= 1.0 then return "●" end -- 100%
    if r > 0.5 then return "◕" end  -- >50%–<100%
    if r > 0.25 then return "◑" end -- >25%–<=50%
    return "◔"                      -- >0%–<=25%
end


local KavitaBrowser = Menu:extend{
    title_shrink_font_to_fit = true,
    -- CoverBrowser integration (set via new() parameters)
    has_coverbrowser = false,
    BookInfoManager = nil,
    CoverMenu = nil,
    ListMenu = nil,
    MosaicMenu = nil,
    offline = false,
    view_kind = nil,
}

function KavitaBrowser:init()
    self.paths = self.paths or {}

    local is_initial_browser_startup = not self.has_initialized_before
    self.has_initialized_before = true

    -- Offline entry (spec 05 A2/A4): same widget, cached data source only.
    if self.offline then
        self.paths = {}
        self.view_kind = "shelf"
        self.item_table = self:buildCacheShelfItems()
        self.catalog_title = _("Cached")
        self.catalog_author = self:_shelfSubtitle()
        self.title_bar_left_icon = "appbar.menu"
        self.onLeftButtonTap = function()
            self:showTitleMenu()
        end
        if self.has_coverbrowser then
            self:_applyCoverBrowserEnhancements()
        end
        Menu.init(self)
        return
    end

    if is_initial_browser_startup and self.servers and #self.servers == 1 then
        local single_server = self.servers[1]
        -- First set up basic properties
        self.item_table = {}
        self.catalog_title = nil
        self.title_bar_left_icon = "appbar.menu"
        self.onLeftButtonTap = function()
            self:showTitleMenu()
        end

        -- Apply CoverBrowser enhancements if available (BEFORE Menu.init)
        if self.has_coverbrowser then
            self:_applyCoverBrowserEnhancements()
        else
            logger.warn("Kamare: CoverBrowser not available")
        end

        -- NOW initialize Menu (after CoverBrowser methods are in place)
        Menu.init(self)

        -- Then load the server's content
        self.current_server_name = single_server.name
        self.current_server_url = single_server.kavita_url or single_server.url
        self:authenticateAfterSelection(single_server.name, single_server.url)
        self:showDashboardAfterSelection(single_server.name)

        return
    end

    -- Normal behavior for multiple servers or no servers
    self.item_table = self:genItemTableFromRoot()
    self.catalog_title = nil
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end

    Menu.init(self)

    -- Apply CoverBrowser enhancements if available
    if self.has_coverbrowser then
        self:_applyCoverBrowserEnhancements()
    else
        logger.warn("Kamare: CoverBrowser not available")
    end
end

function KavitaBrowser:_applyCoverBrowserEnhancements()
    -- Read display mode from CoverBrowser's global FileManager setting
    local display_mode = self.BookInfoManager:getSetting("filemanager_display_mode")

    -- Extract display mode type: "mosaic" or "list"
    local display_mode_type = display_mode and display_mode:gsub("_.*", "") or nil

    -- Only apply CoverBrowser enhancements if not in classic mode
    if not display_mode or display_mode == "" then
        logger.warn("Kamare: Classic mode detected, skipping CoverBrowser enhancements")
        return
    end

    -- Override methods on this instance (same pattern as CoverBrowser does for History/Collections)
    -- Wrap updateItems to force recalculation when page_num is wrong
    local original_updateItems = self.CoverMenu.updateItems
    self.updateItems = function(cover_menu_self, select_number, no_recalculate_dimen)
        -- Force recalculation if page_num doesn't match expected value
        if cover_menu_self.item_table and #cover_menu_self.item_table > 0 and cover_menu_self.perpage and cover_menu_self.perpage > 0 then
            local expected_page_num = math.ceil(#cover_menu_self.item_table / cover_menu_self.perpage)
            if cover_menu_self.page_num ~= expected_page_num then
                no_recalculate_dimen = false
            end
        end

        return original_updateItems(cover_menu_self, select_number, no_recalculate_dimen)
    end

    -- Wrap onCloseWidget to call CoverBrowser's cleanup
    local original_onCloseWidget = self.CoverMenu.onCloseWidget
    self.onCloseWidget = function()
        if original_onCloseWidget then
            original_onCloseWidget(self)
        end
    end

    -- Initialize grid dimensions (same as CoverBrowser.initGrid)
    self.nb_cols_portrait = self.BookInfoManager:getSetting("nb_cols_portrait") or 3
    self.nb_rows_portrait = self.BookInfoManager:getSetting("nb_rows_portrait") or 3
    self.nb_cols_landscape = self.BookInfoManager:getSetting("nb_cols_landscape") or 4
    self.nb_rows_landscape = self.BookInfoManager:getSetting("nb_rows_landscape") or 2
    self.files_per_page = self.BookInfoManager:getSetting("files_per_page") or 8

    self.display_mode_type = display_mode_type

    if self.display_mode_type == "mosaic" then
        -- Replace methods with MosaicMenu versions
        local original_mosaic_recalculate = self.MosaicMenu._recalculateDimen
        self._recalculateDimen = function(...)
            local result = original_mosaic_recalculate(self, ...)

            -- Fix: MosaicMenu calculates page_num = 0 for empty tables, but base Menu returns 1
            self.page_num = math.max(1, self.page_num or 0)

            return result
        end
        self._updateItemsBuildUI = self.MosaicMenu._updateItemsBuildUI

        -- Set MosaicMenu behavior flags
        self._do_cover_images = display_mode ~= "mosaic_text"
        self._do_center_partial_rows = true

    elseif self.display_mode_type == "list" then
        -- Replace methods with ListMenu versions
        local original_listmenu_recalculate = self.ListMenu._recalculateDimen
        self._recalculateDimen = function(...)
            local result = original_listmenu_recalculate(self, ...)

            -- Fix: ListMenu calculates page_num = 0 for empty tables, but base Menu returns 1
            self.page_num = math.max(1, self.page_num or 0)

            return result
        end
        self._updateItemsBuildUI = self.ListMenu._updateItemsBuildUI

        -- Set ListMenu behavior flags
        self._do_cover_images = display_mode ~= "list_only_meta"
        self._do_filename_only = display_mode == "list_image_filename"
    else
        logger.error("Kamare: Unknown display_mode_type - neither mosaic nor list!")
        logger.error("Kamare: This will cause crashes - _recalculateDimen not set")
    end

    -- Disable hint for opened books (we don't track that for Kavita)
    self._do_hint_opened = false

    -- Set up getBookInfo as a function (not method) that CoverBrowser can call
    -- CoverBrowser calls menu.getBookInfo(filepath), not menu:getBookInfo(filepath)
    -- CoverBrowser expects this to ALWAYS return a table, never nil
    self.getBookInfo = function(filepath)
        -- Start with BookInfoManager data (static metadata like title, authors, pages)
        local bookinfo = self.BookInfoManager:getBookInfo(filepath)

        -- For Kavita virtual paths, enhance with live progress from item_table
        if filepath and filepath:match("^/kavita/") then
            -- Find the matching item in item_table
            local kavita_item = nil
            if self.item_table then
                for _, item in ipairs(self.item_table) do
                    if item.file == filepath then
                        kavita_item = item
                        break
                    end
                end
            end

            -- Extract progress from Kavita DTO (series, volume, or chapter)
            local pagesRead, pages = nil, nil
            if kavita_item then
                -- Check for series first (for stream lists like On Deck, Recently Updated, etc.)
                if kavita_item.series then
                    pagesRead = kavita_item.series.pagesRead
                    pages = kavita_item.series.pages
                elseif kavita_item.volume then
                    pagesRead = kavita_item.volume.pagesRead
                    pages = kavita_item.volume.pages
                elseif kavita_item.chapter then
                    pagesRead = kavita_item.chapter.pagesRead
                    pages = kavita_item.chapter.pages
                end
            end

            -- Fallback: use bookinfo pages if DTO doesn't have it
            if not pages and bookinfo and bookinfo.pages then
                pages = bookinfo.pages
            end

            -- Calculate percent_finished
            local percent_finished = nil
            if pagesRead and pages and pages > 0 then
                percent_finished = pagesRead / pages
            end

            -- Determine status
            local status = nil
            if pagesRead and pages and pagesRead >= pages then
                status = "complete"
            end

            -- Build the complete book_info structure
            local result = bookinfo or {}
            result.been_opened = (pagesRead and pagesRead > 0) or false
            result.pages = pages  -- Use calculated pages (DTO or BookInfoManager)
            result.percent_finished = percent_finished
            result.status = status
            result.has_annotations = false

            return result
        end

        -- For regular files, return BookInfoManager data
        if bookinfo then
            return bookinfo
        end

        -- Fallback: always return a valid table (never nil!)
        return { been_opened = false }
    end

    -- Mark as CoverBrowser-enhanced
    self._coverbrowser_overridden = true
end


-- ---------------------------------------------------------------------------
-- Offline cache helpers (spec 02/03/04/05)
-- ---------------------------------------------------------------------------

local function format_bytes(n)
    n = tonumber(n)
    if not n or n <= 0 then return "0 MB" end
    if n >= 1024 * 1024 * 1024 then return string.format("%.1f GB", n / (1024 * 1024 * 1024)) end
    if n >= 1024 * 1024 then return string.format("%.0f MB", n / (1024 * 1024)) end
    return string.format("%.0f KB", n / 1024)
end

local function format_duration(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return T(_("%1 h %2 min"), h, m) end
    return T(_("%1 min"), m)
end

local function append_status(subtitle, status)
    if not status or status == "" then return subtitle end
    if subtitle and subtitle ~= "" then return subtitle .. " · " .. status end
    return status
end

function KavitaBrowser:_cacheContext()
    if self.cache and self.cache.store then return self.cache end
    local Store = require("kamarecachestore")
    local Journal = require("kamarejournal")
    local Queue = require("kamarecachequeue")
    local store = Store:new{}
    local journal = Journal:new{ scheduler = UIManager }
    journal:load()
    local queue = Queue:new{
        store = store, settings = self.kamare_settings, client = KavitaClient,
    }
    queue:load()
    self.cache = { store = store, journal = journal, queue = queue }
    return self.cache
end

function KavitaBrowser:_store() return self:_cacheContext().store end
function KavitaBrowser:_journal() return self:_cacheContext().journal end
function KavitaBrowser:_queue() return self:_cacheContext().queue end

function KavitaBrowser:_serverKeyForCurrent()
    if self.current_server_key then return self.current_server_key end
    if not self.kamare_settings then return nil end
    local entry
    for _, s in ipairs(self.servers or {}) do
        if s.name == self.current_server_name
            or (self.current_server_url and (s.kavita_url == self.current_server_url
                or s.url == self.current_server_url)) then
            entry = s
            break
        end
    end
    if not entry then return nil end
    self.current_server_key = self:_store():resolve_server_key(self.kamare_settings, {
        base_url = entry.kavita_url or entry.url,
        name = entry.name,
    })
    return self.current_server_key
end

function KavitaBrowser:_chapterMeta(chapter_id)
    local key = self.current_server_key
    local sid = self.current_series_id
    if not key or not sid then return nil end
    return self:_store():read_meta(key, sid, chapter_id)
end

function KavitaBrowser:_chapterStatus(server_key, series_id, chapter)
    if not chapter or not chapter.id then return nil end
    local store = self:_store()
    local meta = store:read_meta(server_key, series_id, chapter.id)
    if meta then
        if store:is_stale(server_key, series_id, chapter.id) then return _("Needs update") end
        local pos = self:_journal():get_position(server_key, chapter.id)
        if pos and pos.pageNum and meta.pages then
            if pos.pageNum >= meta.pages then return _("Read · cached") end
            if pos.pageNum > 0 then return _("Reading · cached") end
        elseif pos and pos.pageNum and pos.pageNum > 0 then
            return _("Reading · cached")
        end
        return _("Cached")
    end

    for _, entry in ipairs(self:_queue().entries or {}) do
        if entry.serverKey == server_key and entry.chapterId == chapter.id then
            if entry.state == "extracting" then return _("Extracting") end
            if entry.state == "failed" then return _("Download failed · retry") end
            if entry.state == "downloading" or entry.state == "queued" then
                local part = store:file_size(store:part_path(server_key, chapter.id))
                local total = tonumber(chapter.bytes) or tonumber(entry.archiveBytes)
                if part > 0 and total and total > 0 then
                    return string.format("%s / %s", format_bytes(part), format_bytes(total))
                end
                return _("Queued")
            end
        end
    end

    local part = store:file_size(store:part_path(server_key, chapter.id))
    if part > 0 then
        local total = tonumber(chapter.bytes)
        if total and total > 0 then
            return string.format("%s / %s", format_bytes(part), format_bytes(total))
        end
        return format_bytes(part)
    end
    return nil
end

function KavitaBrowser:_volumeStatus(server_key, series_id, volume)
    local chapters = (type(volume.chapters) == "table") and volume.chapters or {}
    local total, cached, reading, stale = 0, 0, false, false
    for _, ch in ipairs(chapters) do
        total = total + 1
        local meta = self:_store():read_meta(server_key, series_id, ch.id)
        if meta then
            cached = cached + 1
            if self:_store():is_stale(server_key, series_id, ch.id) then stale = true end
            local pos = self:_journal():get_position(server_key, ch.id)
            if pos and pos.pageNum and pos.pageNum > 0 then reading = true end
        end
    end
    if stale then return _("Needs update") end
    if total > 0 and cached == total then
        return reading and _("Reading · cached") or _("Cached")
    end
    if cached > 0 then return T(_("%1/%2 cached"), cached, total) end
    return nil
end

-- Normalize SeriesDetailDto into the flat chapter list stored in series.json.
function KavitaBrowser:_normalizeSeriesChapters(detail)
    local out, seen = {}, {}
    local function add(ch)
        if type(ch) ~= "table" or not ch.id or seen[ch.id] then return end
        seen[ch.id] = true
        local bytes = 0
        local hash
        if type(ch.files) == "table" then
            for _, f in ipairs(ch.files) do bytes = bytes + (tonumber(f.bytes) or 0) end
            hash = ch.files[1] and ch.files[1].koreaderHash
        end
        out[#out + 1] = {
            id = ch.id,
            volumeId = ch.volumeId,
            number = ch.number,
            order = ch.order or ch.sortOrder or (#out + 1),
            title = Utils.buildChapterTitle(ch),
            pages = ch.pages,
            bytes = bytes,
            pagesRead = ch.pagesRead,
            koreaderHash = hash,
            fingerprint = string.format("%s:%s:%s",
                tostring(ch.pages), tostring(bytes), tostring(hash)),
            files = ch.files,
        }
    end
    for _, vol in ipairs(detail.volumes or {}) do
        for _, ch in ipairs(vol.chapters or {}) do add(ch) end
    end
    for _, ch in ipairs(detail.chapters or {}) do add(ch) end
    for _, ch in ipairs(detail.specials or {}) do add(ch) end
    table.sort(out, function(a, b)
        return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
    end)
    return out
end

function KavitaBrowser:_refreshSeriesCache(server_key, series_id, detail)
    local store = self:_store()
    local chapters = self:_normalizeSeriesChapters(detail)
    self._series_chapters_cache = chapters

    -- Free fingerprint comparison while the chapter DTOs are already here.
    store:load_index_or_rebuild(server_key)
    local stale_flags = {}
    for _, c in ipairs(chapters) do
        local meta = store:read_meta(server_key, series_id, c.id)
        if meta and meta.fingerprint then
            stale_flags[c.id] = meta.fingerprint ~= c.fingerprint
        end
    end
    store:update_stale(server_key, stale_flags)

    local series_chapters = {}
    for _, c in ipairs(chapters) do
        series_chapters[#series_chapters + 1] = {
            id = c.id, volumeId = c.volumeId, number = c.number, order = c.order,
            title = c.title, pages = c.pages, bytes = c.bytes,
        }
    end
    store:write_series(server_key, {
        seriesId = series_id,
        seriesName = self.catalog_title,
        libraryId = self.current_series_library_id,
        coverFile = "cover.jpg",
        chapters = series_chapters,
    })
end

function KavitaBrowser:_decorateSeriesItems(items, server_key, series_id)
    for _, item in ipairs(items) do
        local status
        if item.kavita_chapter and item.chapter then
            status = self:_chapterStatus(server_key, series_id, {
                id = item.chapter.id,
                pages = item.chapter.pages,
                bytes = item._cache_bytes,
            })
        elseif item.kavita_volume and item.volume then
            status = self:_volumeStatus(server_key, series_id, item.volume)
        end
        if status then
            item._cache_status = status
            item.author = append_status(item.author, status)
        end
    end
end

function KavitaBrowser:_cacheEntriesFor(chapters)
    local key = self:_server_key_for_current()
    local store = self:_store()
    local sid = self.current_series_id
    if not key or not sid then return {} end
    local out = {}
    for _, c in ipairs(chapters) do
        if not store:has_meta(key, sid, c.id) then
            out[#out + 1] = {
                serverKey = key,
                serverUrl = KavitaClient.base_url,
                seriesId = sid,
                seriesName = self.catalog_title,
                libraryId = self.current_series_library_id,
                volumeId = c.volumeId,
                volumeName = c.volumeName,
                chapterId = c.id,
                chapterTitle = c.title,
                chapterNumber = c.number,
                order = c.order,
                pages = c.pages,
                archiveBytes = c.bytes,
                archiveExt = "cbz",
                koreaderHash = c.koreaderHash,
                files = c.files,
                pagesReadSnapshot = c.pagesRead,
                seriesChapters = self._series_chapters_cache,
            }
        end
    end
    return out
end

function KavitaBrowser:_confirmAndEnqueue(entries)
    if not entries or #entries == 0 then
        UIManager:show(InfoMessage:new{ text = _("Everything selected is already cached") })
        return
    end
    local store = self:_store()
    local total = 0
    for _, e in ipairs(entries) do total = total + (tonumber(e.archiveBytes) or 0) * 2.05 end
    local free = store:free_bytes()
    if free and total > free then
        UIManager:show(InfoMessage:new{
            text = T(_("Not enough space: need about %1, %2 available"),
                format_bytes(total), format_bytes(free)),
        })
        return
    end

    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Cache %1 chapter(s), about %2 (%3 available)?"),
            #entries, format_bytes(total), format_bytes(free or 0)),
        ok_text = _("Download"),
        ok_callback = function()
            UIManager:close(dialog)
            local ok, err = self:_queue():enqueue(entries)
            if not ok then
                UIManager:show(InfoMessage:new{ text = tostring(err) })
            else
                UIManager:show(InfoMessage:new{ text = T(_("Queued %1 chapter(s)"), #entries) })
                self:onCacheStateChanged()
                self:refreshCurrentView()
            end
        end,
    }
    UIManager:show(dialog)
end

function KavitaBrowser:_showSeriesDownloadDialog()
    local cache = self._series_chapters_cache
    if not cache or #cache == 0 then
        UIManager:show(InfoMessage:new{ text = _("No chapters available") })
        return
    end

    local dialog
    local buttons = {{
        {
            text = _("Whole series"),
            callback = function()
                UIManager:close(dialog)
                self:_confirmAndEnqueue(self:_cacheEntriesFor(cache))
            end,
        },
        {
            text = _("From current progress"),
            callback = function()
                UIManager:close(dialog)
                local start = 1
                for i, c in ipairs(cache) do
                    local pos = self:_journal():get_position(self:_server_keyForCurrent() or "", c.id)
                    if (pos and pos.pageNum and pos.pageNum > 0) or (c.pagesRead and c.pagesRead > 0) then
                        start = i
                        break
                    end
                end
                local slice = {}
                for i = start, #cache do slice[#slice + 1] = cache[i] end
                self:_confirmAndEnqueue(self:_cacheEntriesFor(slice))
            end,
        },
    }}
    table.insert(buttons, {
        {
            text = _("Next N volumes…"),
            callback = function()
                UIManager:close(dialog)
                local input
                input = InputDialog:new{
                    title = _("Cache next N volumes"),
                    input_hint = _("Number of volumes"),
                    input_type = "number",
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                        { text = _("OK"), is_enter_default = true, callback = function()
                            local n = tonumber(input:getInputText()) or 0
                            UIManager:close(input)
                            self:_enqueueNextVolumes(n)
                        end },
                    }},
                }
                UIManager:show(input)
                input:onShowKeyboard()
            end,
        },
    })
    dialog = ButtonDialog:new{ title = _("Cache series"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function KavitaBrowser:_enqueueNextVolumes(n)
    if not n or n <= 0 then return end
    local detail = self.current_series_detail
    if not detail then return end
    local key = self:_server_key_for_current()
    local store = self:_store()
    local volumes = {}
    for _, v in ipairs(detail.volumes or {}) do volumes[#volumes + 1] = v end
    table.sort(volumes, function(a, b) return (tonumber(a.number) or 0) < (tonumber(b.number) or 0) end)

    -- Start after the last volume that already has a cached chapter.
    local start = 1
    for i, v in ipairs(volumes) do
        for _, ch in ipairs(v.chapters or {}) do
            if store:has_meta(key, self.current_series_id, ch.id) then start = i + 1 end
        end
    end
    local chapters = {}
    for i = start, math.min(#volumes, start + n - 1) do
        for _, ch in ipairs(volumes[i].chapters or {}) do
            chapters[#chapters + 1] = {
                id = ch.id, volumeId = ch.volumeId, number = ch.number,
                title = Utils.buildChapterTitle(ch), pages = ch.pages,
                order = ch.order, bytes = 0, pagesRead = ch.pagesRead,
                koreaderHash = ch.files and ch.files[1] and ch.files[1].koreaderHash,
                files = ch.files,
            }
            for _, f in ipairs(ch.files or {}) do
                chapters[#chapters].bytes = chapters[#chapters].bytes + (tonumber(f.bytes) or 0)
            end
        end
    end
    self:_confirmAndEnqueue(self:_cacheEntriesFor(chapters))
end

function KavitaBrowser:_wifiOnlyEnabled()
    if not self.kamare_settings then return true end
    return self.kamare_settings:readSetting("download_wifi_only", true) ~= false
end

function KavitaBrowser:_setWifiOnly(enabled)
    if not self.kamare_settings then return end
    self.kamare_settings:saveSetting("download_wifi_only", enabled and true or false)
    pcall(function() self.kamare_settings:flush() end)
    UIManager:show(InfoMessage:new{
        text = enabled and _("Downloads limited to Wi-Fi (best effort)")
            or _("Downloads allowed on any connection"),
    })
end

function KavitaBrowser:_shelfSubtitle()
    local cache = self:_cacheContext()
    local store, journal, queue = cache.store, cache.journal, cache.queue
    local parts = {}
    if self.offline then parts[#parts + 1] = _("Offline: showing cached series only") end
    local usage = store:total_usage()
    if usage.chapters > 0 then
        parts[#parts + 1] = T(_("Used %1 · %2 free"),
            format_bytes(usage.used), format_bytes(store:free_bytes() or 0))
    end
    local status = queue:status()
    if status.pending_count and status.pending_count > 0 and queue:is_paused()
        and status.pause_reason ~= "restored" then
        parts[#parts + 1] = _("Downloads paused")
    end
    if status.state == "downloading" or status.state == "extracting" then
        parts[#parts + 1] = T(_("Downloading %1 / %2 · %3/%4"),
            format_bytes(status.bytes_done), format_bytes(status.bytes_total),
            status.index, status.total)
    end
    local pending = journal:pending_count()
    if pending > 0 then parts[#parts + 1] = T(_("%1 pending sync"), pending) end
    local seconds = journal:session_seconds()
    if seconds > 0 then
        parts[#parts + 1] = T(_("Offline reading %1 (not counted by Kavita)"), format_duration(seconds))
    end
    return table.concat(parts, " · ")
end

function KavitaBrowser:buildCacheShelfItems()
    local store = self:_store()
    local servers, configured = {}, {}
    for _, s in ipairs(self.servers or {}) do
        local key = s.key
        if not key and self.kamare_settings then
            key = store:resolve_server_key(self.kamare_settings, {
                base_url = s.kavita_url or s.url, name = s.name,
            })
        end
        if key then
            configured[key] = true
            servers[#servers + 1] = { key = key, name = s.name, orphan = false }
        end
    end
    for _, key in ipairs(store:list_server_keys()) do
        if not configured[key] then
            servers[#servers + 1] = { key = key, name = T(_("Unlinked server %1"), key), orphan = true }
        end
    end

    local items, orphan_items = {}, {}
    for _, srv in ipairs(servers) do
        local entries = store:load_index_or_rebuild(srv.key)
        local grouped, order = {}, {}
        for _, e in ipairs(entries) do
            local sid = e.seriesId
            if sid then
                if not grouped[sid] then
                    grouped[sid] = {
                        seriesId = sid,
                        seriesName = e.seriesName or T(_("Series %1"), sid),
                        libraryId = e.libraryId,
                        chapters = 0,
                        bytes = 0,
                    }
                    order[#order + 1] = sid
                end
                local g = grouped[sid]
                g.chapters = g.chapters + 1
                g.bytes = g.bytes + (tonumber(e.pagesBytes) or 0)
            end
        end
        for _, sid in ipairs(order) do
            local g = grouped[sid]
            local item = {
                text = g.seriesName,
                author = T(_("%1 chapters · %2"), g.chapters, format_bytes(g.bytes)),
                cache_shelf_series = true,
                _cache_server_key = srv.key,
                _cache_server_name = srv.name,
                _cache_series_id = sid,
                _cache_library_id = g.libraryId,
                _cache_orphan = srv.orphan,
                is_file = true,
                file = string.format("/kamare/cache/%s/series/%s.kamare", srv.key, tostring(sid)),
            }
            if srv.orphan then orphan_items[#orphan_items + 1] = item
            else items[#items + 1] = item end
        end
    end

    table.sort(items, function(a, b) return (a.text or "") < (b.text or "") end)
    table.sort(orphan_items, function(a, b) return (a.text or "") < (b.text or "") end)
    if #orphan_items > 0 then
        items[#items + 1] = {
            text = T(_("Unlinked servers (%1)"), #orphan_items),
            cache_orphan_group = true,
            _orphan_items = orphan_items,
            select_enabled = true,
        }
    end

    local queue_status = self:_queue():status()
    if queue_status.pending_count and queue_status.pending_count > 0 then
        table.insert(items, 1, {
            text = T(_("%1 unfinished download(s) · tap to continue"), queue_status.pending_count),
            author = self:_queue():is_paused() and _("Paused") or _("Queued"),
            cache_resume_downloads = true,
        })
    end

    if #items == 0 or (#items == 1 and items[1].cache_resume_downloads) then
        local resume = items[1]
        items = {}
        if resume then items[1] = resume end
        items[#items + 1] = {
            text = _("No cached chapters · cache some to read offline"),
            select_enabled = false,
            mandatory = "",
        }
        if not self.offline then
            items[#items + 1] = { text = _("Go browse"), cache_go_browse = true }
        end
    end
    return items
end

function KavitaBrowser:showCacheShelf(refresh_only)
    self.view_kind = "shelf"
    self.current_series_detail = nil
    self.offline_shelf = self.offline
    self.catalog_title = _("Cached")
    self.catalog_author = self:_shelfSubtitle()
    if not refresh_only then
        self.paths = self.paths or {}
        table.insert(self.paths, { kavita_cache_shelf = true, title = self.catalog_title })
    end
    self:switchItemTable(self.catalog_title, self:buildCacheShelfItems(), refresh_only and -1 or nil,
        nil, self.catalog_author)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function() self:showTitleMenu() end
end

function KavitaBrowser:_shelfSeriesFromIndex(server_key, series_id)
    local store = self:_store()
    local series = store:read_series(server_key, series_id)
    if series and type(series.chapters) == "table" and #series.chapters > 0 then
        return series
    end
    local fallback = { seriesId = series_id, chapters = {}, libraryId = nil }
    for _, e in ipairs(store:load_index_or_rebuild(server_key)) do
        if e.seriesId == series_id then
            fallback.seriesName = fallback.seriesName or e.seriesName
            fallback.chapters[#fallback.chapters + 1] = {
                id = e.chapterId, volumeId = nil, number = e.chapterNumber,
                order = e.order, title = e.chapterTitle, pages = e.pages, bytes = e.archiveBytes,
            }
        end
    end
    return fallback
end

function KavitaBrowser:showOfflineSeries(item)
    local store = self:_store()
    local key = item._cache_server_key
    local sid = item._cache_series_id
    local series = self:_shelfSeriesFromIndex(key, sid)
    local chapters = series.chapters or {}
    table.sort(chapters, function(a, b) return (tonumber(a.order) or 0) < (tonumber(b.order) or 0) end)

    self.view_kind = "offline_series"
    self.current_series_detail = nil
    self.current_server_key = key
    self.current_series_id = sid
    self.current_series_library_id = series.libraryId or item._cache_library_id
    self.current_series_names = { name = series.seriesName or item.text }
    self.catalog_title = series.seriesName or item.text

    local items, cached_count = {}, 0
    for _, c in ipairs(chapters) do
        local cached = store:has_meta(key, sid, c.id)
        local status = self:_chapterStatus(key, sid, c)
        if cached then cached_count = cached_count + 1 end
        items[#items + 1] = {
            text = c.title or tostring(c.number or c.id),
            author = cached and status or _("Not cached"),
            cache_offline_chapter = true,
            _cache_server_key = key,
            _cache_series_id = sid,
            _chapter_id = c.id,
            chapter = {
                id = c.id, pages = c.pages, volumeId = c.volumeId,
                number = c.number, titleName = c.title, order = c.order,
                pagesRead = 0,
            },
            select_enabled = cached or false,
            is_file = true,
            file = string.format("/kamare/cache/%s/series/%s/chapter/%s.kamare",
                key, tostring(sid), tostring(c.id)),
        }
    end
    self.catalog_author = T(_("%1/%2 chapters cached"), cached_count, #chapters)

    self.paths = self.paths or {}
    table.insert(self.paths, {
        kavita_offline_series = { serverKey = key, seriesId = sid },
        title = self.catalog_title,
    })
    self:switchItemTable(self.catalog_title, items, nil, nil, self.catalog_author)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function() self:showTitleMenu() end
end

function KavitaBrowser:_showOrphanGroup(item)
    self.view_kind = "orphan_group"
    self.current_series_detail = nil
    self.catalog_title = item.text
    self.catalog_author = nil
    self._orphan_items = item._orphan_items
    self.paths = self.paths or {}
    table.insert(self.paths, { kavita_orphan_group = true, title = item.text })
    self:switchItemTable(self.catalog_title, item._orphan_items or {}, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function() self:showTitleMenu() end
end

function KavitaBrowser:_launchLocalChapter(server_key, series_id, chapter_id)
    local store = self:_store()
    local series = store:read_series(server_key, series_id)
    local descriptor
    for _, c in ipairs(series and series.chapters or {}) do
        if c.id == chapter_id then descriptor = c break end
    end
    local meta = store:read_meta(server_key, series_id, chapter_id)
    if not meta then
        UIManager:show(InfoMessage:new{ text = _("Not cached · connect to continue") })
        return
    end
    self.current_server_key = server_key
    self.current_series_id = series_id
    self.current_series_library_id = meta.libraryId
    self.current_series_names = { name = meta.seriesName }
    local chapter = {
        id = chapter_id,
        pages = meta.pages,
        volumeId = meta.volumeId,
        number = meta.chapterNumber,
        titleName = meta.chapterTitle,
        order = meta.order,
        pagesRead = meta.pagesReadSnapshot,
        _from_cache = true,
    }
    -- Let the currently open viewer close itself first (singleton guard).
    UIManager:nextTick(function()
        self:launchKavitaChapterViewer(chapter, meta.seriesName or self.catalog_title, false)
    end)
end

function KavitaBrowser:onCacheStateChanged()
    if self.view_kind == "shelf" then
        UIManager:nextTick(function()
            if self.view_kind == "shelf" then self:showCacheShelf(true) end
        end)
    end
end

function KavitaBrowser:onCacheChapterDone()
    if self.view_kind == "series" then
        self:refreshCurrentView()
    elseif self.view_kind == "shelf" then
        self:showCacheShelf(true)
    end
end

function KavitaBrowser:_syncNow()
    if self.offline or NetworkMgr:isOnline() == false then
        UIManager:show(InfoMessage:new{ text = _("Offline · progress will sync after reconnecting") })
        return
    end
    local active = KamareImageViewer.active_instance
    local current_id = active and active.metadata
        and (active.metadata.chapterId or active.metadata.chapter_id) or nil
    local loading = InfoMessage:new{ text = _("Syncing reading progress…"), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()
    local ok, summary = pcall(self:_journal().sync, self:_journal(), KavitaClient, {
        force_current_chapter = current_id,
    })
    UIManager:close(loading)
    if not ok or not summary then
        UIManager:show(InfoMessage:new{ text = _("Sync failed") })
        return
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Synced: %1 pushed, %2 superseded, %3 failed, %4 skipped"),
            summary.pushed, summary.superseded, summary.failed, summary.skipped),
    })
    if self.view_kind == "shelf" then self:showCacheShelf(true) end
end

function KavitaBrowser:showTitleMenu()
    local dialog
    local buttons = {}

    -- Only show Search when inside a server (i.e., not at root)
    if self.paths and #self.paths > 0 then
        table.insert(buttons, {{
            text = _("Search"),
            callback = function()
                UIManager:close(dialog)
                self:showKavitaSearchDialog()
            end,
            align = "left",
        }})
    end

    if not self.offline then
        table.insert(buttons, {{
            text = _("Cached chapters"),
            callback = function()
                UIManager:close(dialog)
                self:showCacheShelf()
            end,
            align = "left",
        }})
        table.insert(buttons, {{
            text = _("Sync progress now"),
            callback = function()
                UIManager:close(dialog)
                self:_syncNow()
            end,
            align = "left",
        }})
        local queue = self:_queue()
        if #queue.entries > 0 then
            table.insert(buttons, {{
                text = queue:is_paused() and _("Resume downloads") or _("Pause downloads"),
                callback = function()
                    UIManager:close(dialog)
                    if queue:is_paused() then queue:resume() else queue:pause("user") end
                    if self.view_kind == "shelf" then self:showCacheShelf(true) end
                end,
                align = "left",
            }})
        end
        table.insert(buttons, {{
            text = self:_wifiOnlyEnabled() and _("Download over Wi-Fi only: on")
                or _("Download over Wi-Fi only: off"),
            callback = function()
                UIManager:close(dialog)
                self:_setWifiOnly(not self:_wifiOnlyEnabled())
            end,
            align = "left",
        }})
        if self.current_series_detail then
            table.insert(buttons, {{
                text = _("Cache entire series…"),
                callback = function()
                    UIManager:close(dialog)
                    self:_showSeriesDownloadDialog()
                end,
                align = "left",
            }})
        end
    end

    table.insert(buttons, {{
        text = _("Add Kavita server"),
        callback = function()
            UIManager:close(dialog)
            self:addEditServer(nil, false)
        end,
        align = "left",
    }})

    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

-- Build menu entries from the Kavita dashboard array
function KavitaBrowser:buildKavitaDashboardItems(dashboard)
    local items = {}
    if type(dashboard) == "table" then
        for __, d in ipairs(dashboard) do
            local stream_type = d.streamType
            local original_name = d.name or ""
            local api_name
            local name

            if stream_type == 1 then
                api_name = "on-deck"
                name = _("On Deck")
            elseif stream_type == 2 then
                api_name = "recently-updated-series"
                name = _("Recently Updated")
            elseif stream_type == 3 then
                api_name = "recently-added-v2"
                name = _("Newly Added")
            elseif stream_type == 4 then
                api_name = "smart-filter"
                name = Utils.firstNonEmpty(original_name, _("Smart Filter"))
            else
                -- Unknown stream type - use name as-is
                api_name = original_name
                name = Utils.firstNonEmpty(original_name, _("Unnamed"))
            end

            local item = {
                text = name,
                kavita_dashboard = true,
                kavita_stream_name = api_name,
                dashboard = d, -- keep full dto for future navigation
            }

            -- Dashboard items are folders/streams, not files
            -- CoverBrowser needs a path even for directories
            if self.has_coverbrowser then
                item.is_file = false  -- Mark as directory
                -- Provide a dummy directory path
                item.path = string.format("/kavita/%s/stream/%s/",
                    self.current_server_name or "unknown", api_name)
            end

            table.insert(items, item)
        end
    end

    -- Manually add "Want to Read" after the dashboard items
    local item = {
        text = _("Want to Read"),
        kavita_dashboard = true,
        kavita_stream_name = "want-to-read",
        dashboard = { name = "want-to-read" },
    }
    if self.has_coverbrowser then
        item.is_file = false  -- Mark as directory
        -- Provide a dummy directory path
        item.path = string.format("/kavita/%s/stream/want-to-read/",
            self.current_server_name or "unknown")
    end
    table.insert(items, item)

    -- Manually add "Reading Lists" entry (opens the user's reading lists view)
    local rl_item = {
        text = _("Reading Lists"),
        kavita_reading_lists_root = true,
    }
    if self.has_coverbrowser then
        rl_item.is_file = false
        rl_item.path = string.format("/kavita/%s/reading-lists/",
            self.current_server_name or "unknown")
    end
    table.insert(items, rl_item)

    return items
end

-- Fetch dashboard and display it as the server root list
function KavitaBrowser:showDashboardAfterSelection(server_name)
    local loading = InfoMessage:new{ text = T(_("Connecting to %1…"), server_name or _("server")), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local data, code, __, status = KavitaClient:getDashboard()

    UIManager:close(loading)

    if not data then
        self:handleCatalogError("dashboard", "/api/Stream/dashboard", status or code)
        return
    end

    local items = self:buildKavitaDashboardItems(data)
    self.view_kind = "dashboard"
    self.current_series_detail = nil
    self.catalog_title = server_name
    self.search_url = nil

    -- Rebase the stack on the dashboard so Back goes: Stream -> Dashboard -> Servers
    self.paths = { { kavita_dashboard_root = true, title = server_name } }

    self:switchItemTable(self.catalog_title, items, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

function KavitaBrowser:showKavitaSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Kavita"),
        input_hint = _("Enter title, author, tag…"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        if not q or q == "" then
                            UIManager:show(InfoMessage:new{ text = _("Empty search") })
                            return
                        end
                        self:performKavitaSearch(q)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KavitaBrowser:performKavitaSearch(query)
    local loading = InfoMessage:new{ text = T(_("Searching for %1…"), query), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local result, code, __, status = KavitaClient:getSearch(query, false)

    UIManager:close(loading)

    if not result then
        self:handleCatalogError("search", "/api/Search/search", status or code)
        return
    end

    local series_hits = result.series or {}
    local normalized = {}
    for _, hit in ipairs(series_hits) do
        local s = hit.series or hit
        table.insert(normalized, s)
    end

    local items = self:buildKavitaSeriesItems(normalized or {})
    self.catalog_title = _("Search results")
    self.catalog_author = string.format("%s", query)
    self.search_url = nil

    if not items or #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No results") })
    end
    self:switchItemTable(self.catalog_title, items, nil, nil, self.catalog_author)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Build menu entries from a list of SeriesDto
function KavitaBrowser:buildKavitaSeriesItems(series_list)
    local items = {}
    if type(series_list) == "table" then
        for i, s in ipairs(series_list) do
            local name = Utils.firstNonEmpty(s.localizedName, s.name, s.originalName, s.seriesName, s.title, _("Unnamed series"))
            -- Note: SeriesDto doesn't include author/writer info. That's only available
            -- in SeriesDetailDto via chapters. To avoid showing library name as "author",
            -- we leave it empty for series lists.
            local mandatory = progress_icon(s.pagesRead, s.pages)
            local item = {
                text = name,
                author = "",  -- Empty - SeriesDto doesn't have author fields
                mandatory = self.has_coverbrowser and nil or (mandatory or ""),
                kavita_series = true,
                series = s, -- keep full dto for next steps
            }

            -- Add virtual filepath (always set to prevent CoverBrowser crashes)
            if s.id then
                item.file = string.format("/kavita/%s/series/%d.kavita",
                                         self.current_server_name or "unknown",
                                         s.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Build menu entries for VolumeDto[]
function KavitaBrowser:buildKavitaVolumeItems(volumes)
    local items = {}
    if type(volumes) == "table" then
        for _, v in ipairs(volumes) do
            local name = Utils.buildVolumeTitle(v)
            local read = v.pagesRead
            local total = v.pages
            local subtitle = (total and read) and T(_("%1/%2 pages"), tostring(read), tostring(total)) or nil
            local mandatory = progress_icon(read, total)
            local item = {
                text = name,
                author = subtitle,
                mandatory = self.has_coverbrowser and nil or mandatory,
                kavita_volume = true,
                volume = v,
            }

            -- Add virtual filepath (always set to prevent CoverBrowser crashes)
            if v.id then
                item.file = string.format("/kavita/%s/volume/%d.kavita",
                                         self.current_server_name or "unknown",
                                         v.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Build menu entries for ChapterDto[]
function KavitaBrowser:buildKavitaChapterItems(chapters, kind)
    local items = {}
    if type(chapters) == "table" then
        for __, c in ipairs(chapters) do
            local base = Utils.buildChapterTitle(c)

            local name = base
            local read = c.pagesRead
            local total = c.pages
            local subtitle
            if total and read then
                subtitle = T(_("%1/%2 pages"), tostring(read), tostring(total))
            end

            local mandatory = progress_icon(read, total)

            local item = {
                text = name,
                author = subtitle,
                mandatory = self.has_coverbrowser and nil or mandatory,
                kavita_chapter = true,
                chapter = c,
                is_special = (kind == "special") or nil,
            }
            local cache_bytes = 0
            for _, f in ipairs(c.files or {}) do cache_bytes = cache_bytes + (tonumber(f.bytes) or 0) end
            item._cache_bytes = cache_bytes

            -- Add virtual filepath (always set to prevent CoverBrowser crashes)
            if c.id then
                item.file = string.format("/kavita/%s/chapter/%d.kavita",
                                         self.current_server_name or "unknown",
                                         c.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Fetch SeriesDetail and display Volumes, then Chapters, then Specials
function KavitaBrowser:showSeriesDetail(series_name, series_id, library_id, opts)
    local loading = InfoMessage:new{ text = T(_("Loading series %1…"), series_name or _("unknown")), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local detail, code, __, status = KavitaClient:getSeriesDetail(series_id)

    UIManager:close(loading)

    -- Track series context for reader progress (requires seriesId and libraryId)
    self.current_series_id = series_id
    self.current_series_library_id = library_id
    if not self.current_series_library_id then
        local series = KavitaClient:getSeriesById(series_id)
        if type(series) == "table" and series.libraryId then
            self.current_series_library_id = series.libraryId
        end
    end

    if not detail then
        self:handleCatalogError("series", "/api/Series/series-detail?seriesId=" .. tostring(series_id), status or code)
        return
    end

    local items = {}
    for _, it in ipairs(self:buildKavitaVolumeItems(detail.volumes or {})) do table.insert(items, it) end
    for _, it in ipairs(self:buildKavitaChapterItems(detail.chapters or {}, "chapter")) do table.insert(items, it) end
    for _, it in ipairs(self:buildKavitaChapterItems(detail.specials or {}, "special")) do table.insert(items, it) end

    -- Cache integration: fingerprint staleness, series.json, row statuses.
    self.view_kind = "series"
    self.current_series_detail = detail
    self._series_chapters_cache = nil
    local cache_key = self:_serverKeyForCurrent()
    if cache_key then
        self:_refreshSeriesCache(cache_key, series_id, detail)
        self:_decorateSeriesItems(items, cache_key, series_id)
    end

    self.catalog_title = series_name or _("Series")
    self.search_url = nil

    local subtitle
    if detail.volumes and type(detail.volumes) == "table" and detail.volumes[1] then
        local v = detail.volumes[1]
        if v.chapters and type(v.chapters) == "table" and v.chapters[1] then
            subtitle = Utils.joinPersonNames(v.chapters[1].writers)
        end
    end
    if not subtitle and detail.chapters and type(detail.chapters) == "table" and detail.chapters[1] then
        subtitle = Utils.joinPersonNames(detail.chapters[1].writers)
    end
    if not subtitle and detail.specials and type(detail.specials) == "table" and detail.specials[1] then
        subtitle = Utils.joinPersonNames(detail.specials[1].writers)
    end
    self.catalog_author = subtitle
    -- Keep series naming/author for the reader overlay
    self.current_series_names = self.current_series_names or { name = self.catalog_title }
    if not self.current_series_names.author and subtitle then
        self.current_series_names.author = subtitle
    end
    -- Try to enrich names from detail if present
    if type(detail) == "table" then
        local orig = Utils.firstNonEmpty(detail.originalName, detail.series and detail.series.originalName)
        local loc  = Utils.firstNonEmpty(detail.localizedName, detail.series and detail.series.localizedName)
        local nm   = Utils.firstNonEmpty(detail.name, detail.series and detail.series.name)
        if orig and not self.current_series_names.originalName then self.current_series_names.originalName = orig end
        if loc and not self.current_series_names.localizedName then self.current_series_names.localizedName = loc end
        if nm and not self.current_series_names.name then self.current_series_names.name = nm end
    end

    local refresh_only = opts and opts.refresh_only
    -- Push a sentinel so back returns to the stream list (skip when refreshing)
    if not refresh_only then
        self.paths = self.paths or {}
        table.insert(self.paths, { kavita_stream_root = self.current_stream_name, title = self.catalog_title })
    end

    -- Pass -1 to maintain current page when refreshing, nil to reset to page 1
    local itemnumber = refresh_only and -1 or nil
    self:switchItemTable(self.catalog_title, items, itemnumber, nil, self.catalog_author)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Fetch a specific Kavita stream (e.g., on-deck) and display series
-- stream_type: optional streamType (1=OnDeck, 2=RecentlyUpdated, 3=NewlyAdded, 4=SmartFilter)
-- stream_title: optional display title for the stream
-- smart_filter_encoded: optional smartFilterEncoded for smart filters
function KavitaBrowser:showKavitaStream(stream_name, stream_type, stream_title, smart_filter_encoded)
    self.view_kind = "stream"
    self.current_series_detail = nil
    local loading = InfoMessage:new{ text = T(_("Loading %1…"), stream_title or _("stream")), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    -- Determine pagination strategy based on stream type
    local max_pages
    if stream_type then
        if stream_type == 1 or stream_type == 4 then
            -- On Deck (1) and Smart Filter (4): fetch all pages
            max_pages = nil
        else
            -- Recently Updated (2), Newly Added (3): limit to 1 page (50 items)
            max_pages = 1
        end
    elseif stream_name == "want-to-read" then
        -- Manually added want-to-read: fetch all pages
        max_pages = nil
    else
        -- Unknown/fallback: limit to 1 page
        max_pages = 1
    end

    -- Fetch all pages until we get less than page_size results or empty results
    local all_data = {}
    local seen_series_ids = {}
    local page_num = 1
    local page_size = 50
    local has_more = true

    while has_more do
        local params = {
            PageNumber = page_num,
            PageSize = page_size,
        }

        if smart_filter_encoded then
            params.smartFilterEncoded = smart_filter_encoded
        end

        local data, code, __, status = KavitaClient:getStreamSeries(stream_name, params)

        if not data then
            UIManager:close(loading)
            self:handleCatalogError("stream", "/api/Stream/" .. tostring(stream_name), status or code)
            return
        end

        -- Dedup by series id; some Kavita builds ignore the paging params
        if type(data) == "table" and #data > 0 then
            local new_count = 0
            for _, item in ipairs(data) do
                local id = type(item) == "table" and item.id
                if id ~= nil then
                    if not seen_series_ids[id] then
                        seen_series_ids[id] = true
                        table.insert(all_data, item)
                        new_count = new_count + 1
                    end
                else
                    table.insert(all_data, item)
                    new_count = new_count + 1
                end
            end

            -- Check if we should continue fetching
            if new_count == 0 then
                has_more = false
            elseif #data < page_size then
                has_more = false
            elseif max_pages and page_num >= max_pages then
                has_more = false  -- Reached max page limit
            else
                page_num = page_num + 1
            end
        else
            has_more = false
        end
    end

    UIManager:close(loading)

    local data = all_data

    -- Normalize response to a flat array of SeriesDto
    local series_list = data
    if type(data) == "table" and #data == 0 then
        series_list = data.items or data.series or data.data or data.results or data.entries
        if type(series_list) ~= "table" then
            local tmp = {}
            for _, v in pairs(data) do
                if type(v) == "table" then
                    if v.id and (v.name or v.localizedName or v.originalName) then
                        table.insert(tmp, v)
                    elseif type(v[1]) == "table" then
                        for __, vv in ipairs(v) do
                            if type(vv) == "table" and (vv.name or vv.localizedName or vv.originalName) then
                                table.insert(tmp, vv)
                            end
                        end
                    end
                end
            end
            series_list = tmp
        end
    end

    local items = self:buildKavitaSeriesItems(series_list or {})

    -- Remember current stream for back navigation from series detail
    self.current_stream_name = stream_name

    -- Determine title from streamType or provided stream_title
    if not stream_title then
        if stream_type == 1 then
            stream_title = _("On Deck")
        elseif stream_type == 2 then
            stream_title = _("Recently Updated")
        elseif stream_type == 3 then
            stream_title = _("Newly Added")
        elseif stream_type == 4 then
            stream_title = _("Smart Filter")
        elseif stream_name == "want-to-read" then
            stream_title = _("Want to Read")
        else
            stream_title = stream_name
        end
    end

    self.catalog_title = stream_title
    self.search_url = nil

    -- Push stream path so back returns to dashboard
    self.paths = self.paths or {}

    local top = self.paths[#self.paths]

    if not (top and top.kavita_stream_root == stream_name) then
        table.insert(self.paths, {
            kavita_stream_root = stream_name,
            stream_type = stream_type,
            stream_title = stream_title,
            smart_filter_encoded = smart_filter_encoded,
            title = self.catalog_title
        })
    end

    self:switchItemTable(self.catalog_title, items, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Build menu entries from a list of ReadingListDto
function KavitaBrowser:buildKavitaReadingListItems(lists)
    local items = {}
    if type(lists) == "table" then
        for __, rl in ipairs(lists) do
            local title = Utils.firstNonEmpty(rl.title, _("Unnamed list"))
            if rl.promoted then
                title = "★ " .. title
            end

            local subtitle_parts = {}
            if rl.itemCount and rl.itemCount > 0 then
                table.insert(subtitle_parts, tostring(rl.itemCount) .. " " .. _("items"))
            end
            if Utils.firstNonEmpty(rl.ownerUserName) then
                table.insert(subtitle_parts, rl.ownerUserName)
            end
            local subtitle = #subtitle_parts > 0 and table.concat(subtitle_parts, " • ") or nil

            local item = {
                text = title,
                author = subtitle,
                mandatory = self.has_coverbrowser and nil or (rl.itemCount and tostring(rl.itemCount) or ""),
                kavita_reading_list = true,
                reading_list = rl,
            }

            -- Virtual filepath (always set to prevent CoverBrowser crashes)
            if rl.id then
                item.file = string.format("/kavita/%s/reading-list/%d.kavita",
                                          self.current_server_name or "unknown",
                                          rl.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Fetch and display all of the user's reading lists.
-- Mirrors the pagination loop in showKavitaStream.
function KavitaBrowser:showReadingLists()
    self.view_kind = "reading_lists"
    self.current_series_detail = nil
    local loading = InfoMessage:new{ text = _("Loading reading lists…"), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local all_data = {}
    local page_num = 1
    local page_size = 50
    local has_more = true

    while has_more do
        local data, code, __, status = KavitaClient:getReadingLists({
            PageNumber = page_num,
            PageSize   = page_size,
        })

        if not data then
            UIManager:close(loading)
            self:handleCatalogError("reading-lists", "/api/ReadingList/lists", status or code)
            return
        end

        if type(data) == "table" and #data > 0 then
            for _, it in ipairs(data) do
                table.insert(all_data, it)
            end
            if #data < page_size then
                has_more = false
            else
                page_num = page_num + 1
            end
        else
            has_more = false
        end
    end

    UIManager:close(loading)

    local items = self:buildKavitaReadingListItems(all_data)

    self.catalog_title = _("Reading Lists")
    self.search_url = nil

    -- Push path so Back returns to dashboard (skip when already on this view)
    self.paths = self.paths or {}
    local top = self.paths[#self.paths]
    if not (top and top.kavita_reading_lists_root) then
        table.insert(self.paths, {
            kavita_reading_lists_root = true,
            title = self.catalog_title,
        })
    end

    self:switchItemTable(self.catalog_title, items, nil, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Build menu entries from a list of ReadingListItemDto as openable chapters.
-- Each item is synthesized into a ChapterDto-compatible table so the existing
-- launchKavitaChapterViewer and CoverBrowser progress logic work unchanged.
function KavitaBrowser:buildKavitaReadingListItemItems(rli_items)
    local items = {}
    if type(rli_items) == "table" then
        for __, rli in ipairs(rli_items) do
            local ch = rli.chapter or {}
            local series_name = Utils.firstNonEmpty(rli.seriesName, _("Unknown series"))

            local dto_for_title = {
                id        = ch.id or rli.chapterId,
                number    = ch.minNumber,
                isSpecial = ch.isSpecial,
                titleName = ch.titleName,
                title     = rli.title,
                range     = ch.range,
            }
            local chapter_label = Utils.buildChapterTitle(dto_for_title)

            local pages = ch.pages or 0
            local read  = rli.pagesRead or 0
            local subtitle
            if pages and pages > 0 then
                subtitle = T(_("%1/%2 pages"), tostring(read), tostring(pages))
            end
            local mandatory = progress_icon(read, pages)

            -- Carry the writer name through as a writers[] table for the viewer
            local writers
            if Utils.firstNonEmpty(ch.writerName) then
                writers = {{ name = ch.writerName, id = ch.writerId }}
            end

            -- ChapterDto-shaped
            local synthetic_chapter = {
                id         = ch.id or rli.chapterId,
                pages      = ch.pages,
                pagesRead  = rli.pagesRead,
                volumeId   = rli.volumeId,
                range      = ch.range,
                isSpecial  = ch.isSpecial,
                titleName  = ch.titleName,
                number     = ch.minNumber,
                minNumber  = ch.minNumber,
                maxNumber  = ch.maxNumber,
                writers    = writers,
                sortOrder  = ch.sortOrder,
                -- for postReaderProgress (progress is per-series/library)
                seriesId   = rli.seriesId,
                libraryId  = rli.libraryId,
            }

            local item = {
                text = series_name .. " — " .. chapter_label,
                author = subtitle,
                mandatory = self.has_coverbrowser and nil or mandatory,
                kavita_chapter = true,
                chapter = synthetic_chapter,
                is_special = ch.isSpecial or nil,
                reading_list_item = rli,
            }

            if synthetic_chapter.id then
                item.file = string.format("/kavita/%s/chapter/%d.kavita",
                                          self.current_server_name or "unknown",
                                          synthetic_chapter.id)
                item.is_file = true
            end

            table.insert(items, item)
        end
    end
    return items
end

-- Fetch and display the items of a single reading list.
-- opts.refresh_only: when true, do not push a new path entry (used by close/refresh callbacks)
function KavitaBrowser:showReadingListDetail(reading_list_id, reading_list_title, opts)
    self.view_kind = "reading_list"
    self.current_series_detail = nil
    local loading = InfoMessage:new{ text = T(_("Loading %1…"), reading_list_title or _("reading list")), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local items_data, code, __, status = KavitaClient:getReadingListItems(reading_list_id)

    UIManager:close(loading)

    if not items_data then
        self:handleCatalogError("reading-list", "/api/ReadingList/items", status or code)
        return
    end

    -- Ensure ordering by the list's `order` field (API normally returns sorted, but be safe)
    if type(items_data) == "table" then
        table.sort(items_data, function(a, b)
            return (a.order or 0) < (b.order or 0)
        end)
    end

    local items = self:buildKavitaReadingListItemItems(items_data or {})

    self.catalog_title = reading_list_title or _("Reading List")
    self.search_url = nil

    local refresh_only = opts and opts.refresh_only
    if not refresh_only then
        self.paths = self.paths or {}
        local top = self.paths[#self.paths]
        if not (top and top.kavita_reading_list_root == reading_list_id) then
            table.insert(self.paths, {
                kavita_reading_list_root = reading_list_id,
                reading_list_title = reading_list_title,
                title = self.catalog_title,
            })
        end
    end

    -- -1 maintains current page when refreshing, nil resets to page 1
    local itemnumber = refresh_only and -1 or nil
    self:switchItemTable(self.catalog_title, items, itemnumber, nil, nil)
    self:setTitleBarLeftIcon("appbar.menu")
    self.onLeftButtonTap = function()
        self:showTitleMenu()
    end
end

-- Persist bearer token for a server into Kamare settings
function KavitaBrowser:persistBearerToken(server_name, server_url, token)
    if not self.kamare_settings then
        logger.warn("KavitaBrowser:persistBearerToken: no settings")
        return
    end

    local servers = self.kamare_settings:readSetting("servers", {}) or {}
    local found = false

    if type(servers) == "table" then
        for i, s in ipairs(servers) do
            if type(s) == "table" and (s.url == server_url or s.name == server_name) then
                -- Update token and metadata
                servers[i].bearer = token
                servers[i].updated_at = os.time()
                found = true
                break
            end
        end
        if not found then
            -- Insert a new entry with the agreed nomenclature
            table.insert(servers, {
                name = server_name,
                url = server_url,
                bearer = token,
                updated_at = os.time(),
            })
        end
    else
        servers = {
            {
                name = server_name,
                url = server_url,
                bearer = token,
                updated_at = os.time(),
            }
        }
    end

    self.kamare_settings:saveSetting("servers", servers)
    self.servers = servers
end

-- Persist server version in settings (similar to bearer token)
function KavitaBrowser:persistServerVersion(server_name, server_url, version)
    if not self.kamare_settings then
        logger.warn("KavitaBrowser:persistServerVersion: no settings")
        return
    end

    local servers = self.kamare_settings:readSetting("servers", {}) or {}
    local found = false

    if type(servers) == "table" then
        for i, s in ipairs(servers) do
            if type(s) == "table" and (s.url == server_url or s.name == server_name) then
                -- Update version and metadata
                servers[i].version = version
                servers[i].updated_at = os.time()
                found = true
                break
            end
        end
        if not found then
            -- Insert a new entry with version info
            table.insert(servers, {
                name = server_name,
                url = server_url,
                version = version,
                updated_at = os.time(),
            })
        end
    else
        servers = {
            {
                name = server_name,
                url = server_url,
                version = version,
                updated_at = os.time(),
            }
        }
    end

    self.kamare_settings:saveSetting("servers", servers)
    self.servers = servers
end

-- Check if we should use API key authentication (version >= 0.8.9.0)
function KavitaBrowser:shouldUseApiKeyAuth(server_name, server_url)
    if not self.kamare_settings then
        return false  -- No settings → use legacy method (safe)
    end

    local servers = self.kamare_settings:readSetting("servers", {}) or {}

    for _, server in ipairs(servers) do
        if (server.url == server_url or server.name == server_name) and server.version then
            if KavitaClient:compareVersions(server.version, "0.8.9.0") >= 0 then
                return true  -- Use API key method
            else
                return false -- Use bearer method
            end
        end
    end

    -- No version info → use legacy bearer method (safe default)
    return false
end

-- Authenticate after selecting a server using config (no dialog)
function KavitaBrowser:authenticateAfterSelection(server_name, server_url)
    if not self.kamare_settings then
        logger.warn("KavitaBrowser:authenticateAfterSelection: no settings available")
        return
    end

    local servers = self.kamare_settings:readSetting("servers", {}) or {}

    -- Always (re)authenticate after selection to ensure fresh token

    -- Find matching server entry
    local entry
    for i, s in ipairs(servers) do
        if type(s) == "table" and (s.url == server_url or s.name == server_name) then
            entry = s
            break
        end
    end
    if not entry then
        logger.warn("KavitaBrowser:authenticateAfterSelection: server entry not found", server_name, server_url)
        return
    end

    -- Resolve API key and base server URL (no fallbacks)
    local apiKey = entry.api_key
    local base_url = entry.kavita_url

    if not apiKey or apiKey == "" or not base_url or base_url == "" then
        logger.warn("KavitaBrowser:authenticateAfterSelection: missing api_key or kavita_url")
        return
    end

    self.current_server_url = base_url
    self.current_server_key = nil

    -- Keep client api_key for endpoints that require it as query param
    KavitaClient.api_key = apiKey
    KavitaClient.base_url = base_url

    -- Check if we should use API key authentication (version >= 0.8.9.0)
    local should_use_api_key = self:shouldUseApiKeyAuth(server_name, server_url)

    if should_use_api_key then
        -- New method: Just use API key, skip bearer token request
        KavitaClient.auth_method = "apiKey"
        logger.info("Using API key authentication for server:", server_name)
    else
        -- Old method: Request bearer token
        local token, code, __, err = KavitaClient:authenticate(base_url, apiKey)
        if not token then
            logger.warn("KavitaBrowser:authenticateAfterSelection: authentication failed", code, err)
            return
        end
        KavitaClient.bearer = token
        KavitaClient.auth_method = "bearer"
        self:persistBearerToken(server_name, server_url, token)
    end

    -- Check kavita server version for compatibility (for logging/info)
    local version, code, __, status = KavitaClient:getKavitaVersion()

    if version and code == 200 then
        logger.info("Kavita server version check: " .. version .. " " .. code)
        -- Persist the server version in settings
        self:persistServerVersion(server_name, server_url, version)
    else
        logger.warn("Kavita server version check failed:", status or "unknown error", "code:", code)
    end
end


local function buildRootEntry(server)
    return {
        text       = server.name,
        url        = server.kavita_url,
        searchable = server.kavita_url and server.kavita_url:match("%%s") and true or false,
    }
end

-- Builds the root list of catalogs
function KavitaBrowser:genItemTableFromRoot()
    local item_table = {}
    if self.servers then
        for _, server in ipairs(self.servers) do
            table.insert(item_table, buildRootEntry(server))
        end
    end
    return item_table
end

-- Shows dialog to edit properties of the new/existing catalog
function KavitaBrowser:addEditServer(item, is_edit)
    if is_edit == nil then is_edit = item ~= nil end
    local fields = {
        {
            hint = _("Server name"),
        },
        {
            hint = _("Server URL"),
        },
        {
            hint = _("API key"),
        },
    }
    local title
    if is_edit then
        title = _("Edit Kavita server")
        fields[1].text = item.text
        fields[2].text = item.url
        fields[3].text = (self.servers and self.servers[item.idx] and self.servers[item.idx].api_key) or nil
    else
        title = _("Add Kavita server")
    end

    local button_text = is_edit and _("Save") or _("Add")
    local dialog
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = button_text,
                    callback = function()
                        local new_fields = dialog:getFields()
                        self:editServerFromInput(new_fields, item)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end


-- Saves catalog properties from input dialog
function KavitaBrowser:editServerFromInput(fields, item)
    local new_server = {
        name        = fields[1],
        kavita_url  = fields[2]:match("^%a+://") and fields[2] or "http://" .. fields[2],
        api_key     = Utils.firstNonEmpty(fields[3]),
    }
    local new_item = buildRootEntry(new_server)
    local new_idx, itemnumber

    -- Initialize servers table if it doesn't exist
    if not self.servers then
        self.servers = {}
    end

    if item then
        new_idx = item.idx
        itemnumber = -1
    else
        new_idx = #self.servers + 1
        itemnumber = new_idx
    end
    self.servers[new_idx] = new_server
    self.item_table[new_idx] = new_item
    self:switchItemTable(nil, self.item_table, itemnumber)

    -- Save servers to settings (will be flushed by main plugin)
    if self.kamare_settings then
        self.kamare_settings:saveSetting("servers", self.servers)
    end
end

-- Deletes catalog from the root list
function KavitaBrowser:deleteCatalog(item)
    table.remove(self.servers, item.idx)
    table.remove(self.item_table, item.idx)
    self:switchItemTable(nil, self.item_table, -1)

    -- Save servers to settings (will be flushed by main plugin)
    if self.kamare_settings then
        self.kamare_settings:saveSetting("servers", self.servers)
    end
end

-- Handle errors from catalog fetching
function KavitaBrowser:handleCatalogError(context, item_url, error_msg)
    logger.info("Cannot get catalog info from", item_url, error_msg)

    local message
    if context == "dashboard" then
        message = _("Cannot load dashboard. Please check your connection.")
    elseif context == "search" then
        message = _("Search failed. Please try again.")
    elseif context == "series" then
        message = _("Cannot load series details. Please check your connection.")
    elseif context == "stream" then
        message = _("Cannot load content. Please check your connection.")
    elseif context == "reading-lists" then
        message = _("Cannot load reading lists. Please check your connection.")
    elseif context == "reading-list" then
        message = _("Cannot load reading list. Please check your connection.")
    else
        message = _("Cannot load data from server. Please check your connection.")
    end

    UIManager:show(InfoMessage:new{
        text = message,
    })
end

-- Refresh whatever view is currently on top of the path stack.
-- Used by viewer on_close and "mark as read" flows so the right screen is
-- refreshed (reading list vs. series detail) instead of always jumping to
-- series detail.
function KavitaBrowser:refreshCurrentView()
    if self.view_kind == "shelf" then
        self:showCacheShelf(true)
        return
    end
    if self.view_kind == "offline_series" then
        local top = self.paths and self.paths[#self.paths]
        if top and top.kavita_offline_series then
            self.paths = self.paths or {}
            table.remove(self.paths)
            self:showOfflineSeries({
                _cache_server_key = top.kavita_offline_series.serverKey,
                _cache_series_id = top.kavita_offline_series.seriesId,
                text = top.title,
            })
            return
        end
    end
    local top = self.paths and self.paths[#self.paths]
    if top and top.kavita_reading_list_root then
        UIManager:nextTick(function()
            self:showReadingListDetail(
                top.kavita_reading_list_root,
                top.reading_list_title or top.title,
                { refresh_only = true }
            )
        end)
        return
    end
    -- Default: refresh the current series detail (if any)
    local sid = self.current_series_id
    if not sid then return end
    local lid = self.current_series_library_id
    local sname = self.catalog_title
        or (self.current_series_names and Utils.firstNonEmpty(self.current_series_names.localizedName, self.current_series_names.name))
        or _("Series")
    UIManager:nextTick(function()
        self:showSeriesDetail(sname, sid, lid, { refresh_only = true })
    end)
end

-- Launch the Kavita chapter viewer using Reader/image endpoint
function KavitaBrowser:launchKavitaChapterViewer(chapter, series_name, is_volume, override_view_mode)
    if not chapter or not chapter.id then return end

    -- Singleton guard: refuse to launch if a viewer is already open
    if KamareImageViewer.active_instance then
        logger.dbg("KavitaBrowser: KamareImageViewer already active, ignoring launch request")
        return
    end

    local cache_key = self:_serverKeyForCurrent()
    local cache_store = self:_store()
    local series_id = chapter.seriesId or self.current_series_id
    local local_meta
    if cache_key and series_id then
        local_meta = cache_store:read_meta(cache_key, series_id, chapter.id)
    end
    local local_mode = local_meta ~= nil or self.offline == true
    if local_mode and not local_meta then
        UIManager:show(InfoMessage:new{ text = _("Not cached · connect to download") })
        return
    end

    local pages = (local_meta and local_meta.pages)
        or chapter.pages or (chapter.files and #chapter.files) or 0
    if pages <= 0 then
        local message = is_volume and _("This volume has no pages to display") or _("This chapter has no pages to display")
        UIManager:show(InfoMessage:new{ text = message })
        return
    end

    -- Show loading indicator
    local loading = InfoMessage:new{ text = is_volume and _("Opening volume…") or _("Opening chapter…"), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    -- Make sure client has bearer/base_url/api_key (authenticateAfterSelection sets those)
    local page_table = KavitaClient:streamChapter(chapter.id)

    -- Keep lazy 1-based images list; client converts to 0-based for API
    local images_list_data = page_table

    -- Start page priority (05 A5): journal position > cached snapshot > pagesRead.
    local start_page = 1
    if local_meta then
        local pos = self:_journal():get_position(cache_key, chapter.id)
        local pr = pos and tonumber(pos.pageNum)
        if pr and pr > 0 then
            start_page = math.min(pr, pages)
        elseif tonumber(local_meta.pagesReadSnapshot or 0) > 0 then
            start_page = math.min(local_meta.pagesReadSnapshot, pages)
        end
    elseif type(chapter.pagesRead) == "number" then
        local pr = math.max(0, math.floor(chapter.pagesRead))
        if pr >= pages then
            start_page = pages
        else
            start_page = pr + 1
        end
    end

    local author =
        (self.current_series_names and Utils.joinPersonNames(self.current_series_names.author))
        or self.catalog_author
        or Utils.joinPersonNames(chapter.writers)

    local series_names = self.current_series_names or {}

    local content_type = "auto"

    if is_volume == true then
        content_type = "volume"
    elseif is_volume == false then
        content_type = "chapter"
    elseif is_volume == nil then
        -- Auto-detect based on chapter.range
        -- Kavita uses -100000 as sentinel value for volumes
        -- Positive numbers indicate chapter numbers
        if chapter.range then
            local range = tonumber(chapter.range)
            if range and range < 0 then
                content_type = "volume"
            elseif range and range >= 0 then
                content_type = "chapter"
            end
        end
    end

    local metadata = {
        -- Primary labels
        seriesName    = Utils.firstNonEmpty(series_name, series_names.localizedName, series_names.name),
        author        = author,

        -- Alternate/localized/original names if known
        originalName  = series_names.originalName,
        localizedName = series_names.localizedName,

        -- IDs for progress/integration
        seriesId      = self.current_series_id,
        libraryId     = self.current_series_library_id,
        volumeId      = chapter.volumeId,
        chapterId     = chapter.id,

        -- Keep raw chapter for any further needs
        chapter       = chapter,

        -- Reader state
        startPage     = start_page,

        content_type  = content_type,

        -- Cache identity / offline metadata
        serverKey     = cache_key,
        chapterTitle  = (local_meta and local_meta.chapterTitle) or chapter.titleName,
        offline       = self.offline == true,
    }


    local preloaded_dimensions
    if local_meta then
        preloaded_dimensions = {}
        if #(local_meta.dims or {}) < pages then
            UIManager:show(InfoMessage:new{
                text = _("Cached metadata is incomplete · reconnect to refresh this chapter"),
                timeout = 3,
            })
        end
        for i, d in ipairs(local_meta.dims or {}) do
            local w, h = d[1] or 0, d[2] or 0
            preloaded_dimensions[i] = {
                pageNumber = i, width = w, height = h, isWide = w > h,
                fileName = string.format("%04d.jpg", i),
            }
        end
    else
    do
        local dims, code = KavitaClient:getFileDimensions(chapter.id)
        if type(code) == "number" and code >= 200 and code < 300 and type(dims) == "table" then
            -- Convert possible 0-based page indices to 1-based for the viewer
            local zero_based = false
            for _, d in ipairs(dims) do
                local pn = d.pageNumber or d.page or d.page_num
                if type(pn) == "number" and pn == 0 then
                    zero_based = true
                    break
                end
            end
            if zero_based then
                for _, d in ipairs(dims) do
                    if type(d.pageNumber) == "number" then d.pageNumber = d.pageNumber + 1 end
                    if type(d.page) == "number" then d.page = d.page + 1 end
                    if type(d.page_num) == "number" then d.page_num = d.page_num + 1 end
                end
            end
            preloaded_dimensions = dims
        else
            logger.warn("KavitaBrowser: getFileDimensions failed:", code)
        end
    end
    end

    local preloaded_iswide = {}
    if type(preloaded_dimensions) == "table" then
        for _, d in ipairs(preloaded_dimensions) do
            local pn = d.pageNumber or d.page or d.page_num
            if type(pn) == "number" then
                preloaded_iswide[pn] = d.isWide and true or false
            end
        end
    end

    local viewer = KamareImageViewer:new{
        ui = self.ui,
        images_list_data = images_list_data,
        title = Utils.firstNonEmpty(metadata.seriesName, _("Manga")),
        fullscreen = true,
        with_title_bar = false,
        images_list_nb = pages,
        preloaded_dimensions = preloaded_dimensions,
        preloaded_iswide = preloaded_iswide,
        metadata = metadata,
        kamare_settings = self.kamare_settings,
        override_view_mode = override_view_mode,
        page_source = local_mode and "local" or "network",
        offline = self.offline == true,
        local_meta = local_meta,
        cache_store = local_mode and cache_store or nil,
        cache_server_key = cache_key,
        cache_journal = local_mode and self:_journal() or nil,
        on_close_callback = function(current_page, total_pages)
            self:refreshCurrentView()
        end,
        on_next_chapter_callback = function(next_chapter_id)
            -- Cached chapter: open locally, no network at all.
            local next_key = self:_serverKeyForCurrent()
            if next_key and self.current_series_id
                and self:_store():has_meta(next_key, self.current_series_id, next_chapter_id) then
                self:_launchLocalChapter(next_key, self.current_series_id, next_chapter_id)
                return
            end
            if self.offline then
                UIManager:show(InfoMessage:new{ text = _("Not cached · connect to continue") })
                return
            end
            -- Fetch the next chapter details and launch viewer
            UIManager:nextTick(function()
                local next_loading = InfoMessage:new{ text = _("Loading next chapter…"), timeout = 0 }
                UIManager:show(next_loading)
                UIManager:forceRePaint()

                -- Get series detail to find the chapter
                local sid = self.current_series_id
                if not sid then
                    UIManager:close(next_loading)
                    UIManager:show(InfoMessage:new{ text = _("Cannot load next chapter: missing series info") })
                    return
                end

                local detail = KavitaClient:getSeriesDetail(sid)
                UIManager:close(next_loading)

                if not detail then
                    UIManager:show(InfoMessage:new{ text = _("Failed to load next chapter") })
                    return
                end

                -- Find the chapter with matching ID
                local next_chapter
                if detail.volumes then
                    for _, vol in ipairs(detail.volumes) do
                        if vol.chapters then
                            for _, ch in ipairs(vol.chapters) do
                                if ch.id == next_chapter_id then
                                    next_chapter = ch
                                    break
                                end
                            end
                        end
                        if next_chapter then break end
                    end
                end
                if not next_chapter and detail.chapters then
                    for _, ch in ipairs(detail.chapters) do
                        if ch.id == next_chapter_id then
                            next_chapter = ch
                            break
                        end
                    end
                end
                if not next_chapter and detail.specials then
                    for _, ch in ipairs(detail.specials) do
                        if ch.id == next_chapter_id then
                            next_chapter = ch
                            break
                        end
                    end
                end

                if not next_chapter then
                    UIManager:show(InfoMessage:new{ text = _("Next chapter not found") })
                    return
                end

                local sname = self.catalog_title
                    or (self.current_series_names and Utils.firstNonEmpty(self.current_series_names.localizedName, self.current_series_names.name))
                    or _("Series")
                self:launchKavitaChapterViewer(next_chapter, sname)
            end)
        end,
    }

    if viewer._aborted then
        logger.dbg("KavitaBrowser: KamareImageViewer init aborted (duplicate), discarding")
        UIManager:close(loading)
        return
    end

    -- Do initial prefetch
    if viewer and viewer.virtual_document then
        viewer:prefetchUpcomingTiles()
    end

    UIManager:close(loading)
    UIManager:show(viewer)
    return viewer
end

-- Menu action on item tap (Stream a book / Show subcatalog / Search in catalog)
function KavitaBrowser:onMenuSelect(item)
    if item.cache_resume_downloads then
        self:_queue():resume()
        UIManager:show(InfoMessage:new{ text = _("Download queue resumed") })
        self:showCacheShelf(true)
        return true
    end
    if item.cache_orphan_group then
        self:_showOrphanGroup(item)
        return true
    end
    if item.cache_go_browse then
        if self.offline then
            UIManager:show(InfoMessage:new{ text = _("Connect to browse the server") })
        else
            self:init()
        end
        return true
    end
    if item.cache_shelf_series then
        self.current_server_key = item._cache_server_key
        if self.offline or item._cache_orphan then
            self:showOfflineSeries(item)
        else
            self.current_server_name = item._cache_server_name
            self:showSeriesDetail(item.text, item._cache_series_id, item._cache_library_id)
        end
        return true
    end
    if item.cache_offline_chapter then
        local store = self:_store()
        if store:has_meta(item._cache_server_key, item._cache_series_id, item._chapter_id) then
            self:_launchLocalChapter(item._cache_server_key, item._cache_series_id, item._chapter_id)
        else
            UIManager:show(InfoMessage:new{ text = _("Not cached · connect to download") })
        end
        return true
    end

    -- Only Kavita items are supported
    if item.kavita_chapter and item.chapter and item.chapter.id then
        -- Reading-list chapter items: stash series context so the viewer can
        -- post progress against the correct series/library.
        if item.reading_list_item then
            local rli = item.reading_list_item
            self.current_series_id = rli.seriesId
            self.current_series_library_id = rli.libraryId
            self.current_series_names = {
                name = rli.seriesName,
                author = Utils.firstNonEmpty(
                    Utils.joinPersonNames(item.chapter.writers),
                    rli.chapter and rli.chapter.writerName
                ),
            }
            self:launchKavitaChapterViewer(item.chapter, rli.seriesName or self.catalog_title, false)
            return true
        end
        self:launchKavitaChapterViewer(item.chapter, self.catalog_title or self.current_server_name, false)
        return true
    end

    if item.kavita_volume and item.volume and item.volume.id then
        local vol = item.volume
        local ch = (type(vol.chapters) == "table") and vol.chapters[1] or nil
        if ch and ch.id then
            self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
        else
            UIManager:show(InfoMessage:new{ text = _("This volume has no chapters available.") })
        end
        return true
    end

    if item.kavita_recently_added and item.recent and item.recent.seriesId then
        self:showSeriesDetail(item.text, item.recent.seriesId, nil)
        return true
    end

    if item.kavita_series and item.series then
        local sid = item.series.id or item.series.seriesId
        local lid = item.series.libraryId or (item.series.library and item.series.library.id)
        if sid then
            -- Remember series naming metadata for the reader
            local s = item.series or {}
            self.current_series_names = {
                name = item.text,
                originalName = Utils.firstNonEmpty(s.originalName, s.seriesName, s.name),
                localizedName = s.localizedName,
                -- Raw author data if present; will be normalized later
                author = Utils.firstNonEmpty(s.author, s.authors, s.writers),
            }
            self:showSeriesDetail(item.text, sid, lid)
            return true
        end
    end

    if item.kavita_reading_lists_root then
        self:showReadingLists()
        return true
    end

    if item.kavita_reading_list then
        local rl = item.reading_list
        if not rl or not rl.id then
            UIManager:show(InfoMessage:new{ text = _("Invalid reading list") })
            return true
        end
        self:showReadingListDetail(rl.id, item.text)
        return true
    end

    if item.kavita_dashboard then
        local stream_name = item.kavita_stream_name or (item.dashboard and item.dashboard.name)
        if not stream_name or stream_name == "" then
            UIManager:show(InfoMessage:new{ text = _("Invalid dashboard item") })
            return true
        end

        self:showKavitaStream(
            stream_name,
            item.dashboard and item.dashboard.streamType,
            item.text,
            item.dashboard and item.dashboard.smartFilterEncoded
        )

        return true
    end

    if #self.paths == 0 then -- root list
        self.current_server_name    = item.text
        self.current_server_url     = item.url
        self.current_server_key     = nil
        self:authenticateAfterSelection(item.text, item.url)
        self:showDashboardAfterSelection(item.text)
        return true
    end

    return true
end

-- Show series information dialog with metadata
function KavitaBrowser:showSeriesInfo(series_name, series_id)
    if not series_id then
        UIManager:show(InfoMessage:new{ text = _("Series ID not available") })
        return
    end

    local loading = InfoMessage:new{ text = T(_("Loading info for %1…"), series_name or _("series")), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local metadata, code, headers, status = KavitaClient:getSeriesMetadata(series_id)

    UIManager:close(loading)

    if not metadata then
        UIManager:show(InfoMessage:new{ text = _("Failed to load series info") })
        logger.warn("KavitaBrowser:showSeriesInfo: failed to get metadata", code, status)
        return
    end

    -- Helper to wrap text in bold markers (Poor Text Formatting)
    local function bold(text)
        return "\u{FFF2}" .. text .. "\u{FFF3}"
    end

    -- Helper function to format tag arrays
    local function formatTags(tags)
        if not tags or type(tags) ~= "table" or #tags == 0 then
            return nil
        end
        local names = {}
        for _, t in ipairs(tags) do
            if type(t) == "table" and t.title then
                table.insert(names, t.title)
            elseif type(t) == "string" then
                table.insert(names, t)
            end
        end
        return #names > 0 and table.concat(names, ", ") or nil
    end

    -- Build the info text
    local info_parts = {}

    -- Start with PTF header to enable formatting
    table.insert(info_parts, "\u{FFF1}")

    -- Summary/Description (most important, show first)
    if Utils.firstNonEmpty(metadata.summary) then
        table.insert(info_parts, metadata.summary)
        table.insert(info_parts, "")
    end

    -- Build metadata section
    local meta_items = {}

    -- Publication Status
    if metadata.publicationStatus then
        local status_text
        if metadata.publicationStatus == 0 then
            status_text = _("Ongoing")
        elseif metadata.publicationStatus == 1 then
            status_text = _("Completed")
        elseif metadata.publicationStatus == 2 then
            status_text = _("Cancelled")
        elseif metadata.publicationStatus == 3 then
            status_text = _("Hiatus")
        elseif metadata.publicationStatus == 4 then
            status_text = _("Ended")
        end
        if status_text then
            table.insert(meta_items, _("Status: ") .. status_text)
        end
    end

    -- Release Year
    if metadata.releaseYear and metadata.releaseYear > 0 then
        table.insert(meta_items, _("Year: ") .. tostring(metadata.releaseYear))
    end

    if #meta_items > 0 then
        table.insert(info_parts, table.concat(meta_items, " • "))
        table.insert(info_parts, "")
    end

    -- Genres
    local genres = formatTags(metadata.genres)
    if genres then
        table.insert(info_parts, bold(_("Genres:")) .. " " .. genres)
    end

    -- Tags
    local tags = formatTags(metadata.tags)
    if tags then
        table.insert(info_parts, bold(_("Tags:")) .. " " .. tags)
    end

    -- Add spacing if we have genres/tags
    if genres or tags then
        table.insert(info_parts, "")
    end

    -- Credits section
    local credits = {}

    local writers = Utils.joinPersonNames(metadata.writers)
    if writers then
        table.insert(credits, bold(_("Writers:")) .. " " .. writers)
    end

    local publishers = Utils.joinPersonNames(metadata.publishers)
    if publishers then
        table.insert(credits, bold(_("Publishers:")) .. " " .. publishers)
    end

    local translators = Utils.joinPersonNames(metadata.translators)
    if translators then
        table.insert(credits, bold(_("Translators:")) .. " " .. translators)
    end

    -- Art credits
    local cover_artists = Utils.joinPersonNames(metadata.coverArtists)
    if cover_artists then
        table.insert(credits, bold(_("Cover Art:")) .. " " .. cover_artists)
    end

    local pencillers = Utils.joinPersonNames(metadata.pencillers)
    if pencillers then
        table.insert(credits, bold(_("Pencils:")) .. " " .. pencillers)
    end

    local inkers = Utils.joinPersonNames(metadata.inkers)
    if inkers then
        table.insert(credits, bold(_("Inks:")) .. " " .. inkers)
    end

    local colorists = Utils.joinPersonNames(metadata.colorists)
    if colorists then
        table.insert(credits, bold(_("Colors:")) .. " " .. colorists)
    end

    local letterers = Utils.joinPersonNames(metadata.letterers)
    if letterers then
        table.insert(credits, bold(_("Letters:")) .. " " .. letterers)
    end

    local editors = Utils.joinPersonNames(metadata.editors)
    if editors then
        table.insert(credits, bold(_("Editors:")) .. " " .. editors)
    end

    if #credits > 0 then
        for _, credit in ipairs(credits) do
            table.insert(info_parts, credit)
        end
    end

    local info_text = table.concat(info_parts, "\n")

    -- Show the info in a TextViewer
    local text_viewer = TextViewer:new{
        title = series_name or _("Series Info"),
        text = info_text,
        justified = false,
    }
    UIManager:show(text_viewer)
end

-- Menu action on item long-press (dialog Edit / Delete catalog)
function KavitaBrowser:onMenuHold(item)
    -- Handle series long-press for continue reading
    if item.kavita_series and item.series then
        local series = item.series
        local sid = series.id or series.seriesId
        local lid = series.libraryId or (series.library and series.library.id)

        if not sid then
            UIManager:show(InfoMessage:new{ text = _("Series ID not available") })
            return true
        end

        local dialog
        local buttons = {
            {
                {
                    text = _("Continue Reading") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)

                        local loading = InfoMessage:new{ text = T(_("Resuming %1…"), item.text or _("series")), timeout = 0 }
                        UIManager:show(loading)
                        UIManager:forceRePaint()

                        local chapter = KavitaClient:getContinuePoint(sid)

                        UIManager:close(loading)

                        if not chapter then
                            UIManager:show(InfoMessage:new{ text = _("Failed to get continue point") })
                            return
                        end

                        self.current_series_id = sid
                        self.current_series_library_id = lid
                        self.current_series_names = {
                            name = item.text,
                            originalName = Utils.firstNonEmpty(series.originalName, series.seriesName, series.name),
                            localizedName = series.localizedName,
                            author = Utils.firstNonEmpty(series.author, series.authors, series.writers),
                        }

                        self:launchKavitaChapterViewer(chapter, item.text)
                    end,
                },
                {
                    text = _("View Series"),
                    callback = function()
                        UIManager:close(dialog)
                        self.current_series_names = {
                            name = item.text,
                            originalName = Utils.firstNonEmpty(series.originalName, series.seriesName, series.name),
                            localizedName = series.localizedName,
                            author = Utils.firstNonEmpty(series.author, series.authors, series.writers),
                        }
                        self:showSeriesDetail(item.text, sid, lid)
                    end,
                },
            },
            {
                {
                    text = "\u{F05A} " .. _("Series Info"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showSeriesInfo(item.text, sid)
                    end,
                },
            },
        }

        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    -- Handle chapter/volume long-press for reading options
    if item.kavita_chapter and item.chapter and item.chapter.id then
        local chapter = item.chapter
        local pages = chapter.pages or (chapter.files and #chapter.files) or 0
        if pages <= 0 then
            UIManager:show(InfoMessage:new{ text = _("This chapter has no pages to display") })
            return true
        end

        local dialog
        local buttons = {
            {
                {
                    text = "\u{2194} " .. _("Page mode"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Launch in page mode (view_mode=0), continue from last position
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false, 0)
                    end,
                },
                {
                    text = "\u{2195} " .. _("Continuous"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Launch in continuous mode (view_mode=1), continue from last position
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false, 1)
                    end,
                },
            },
            {},  -- separator
            {
                {
                    text = "\u{23EE} " .. _("From start"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Override start page to 1
                        local original_pages_read = chapter.pagesRead
                        chapter.pagesRead = 0
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false)
                        chapter.pagesRead = original_pages_read
                    end,
                },
                {
                    text = _("Continue") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)
                        -- Use normal behavior (resume from pagesRead)
                        self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false)
                    end,
                },
            },
        }

        -- Add "Jump to" option if there are pages to jump to
        if pages > 1 then
            table.insert(buttons, {
                {
                    text = _("Jump to page") .. " \u{23E9}",
                    callback = function()
                        UIManager:close(dialog)
                        local jump_dialog
                        jump_dialog = InputDialog:new{
                            title = _("Jump to page"),
                            input_hint = T(_("1 - %1"), pages),
                            input_type = "number",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(jump_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Jump"),
                                        is_enter_default = true,
                                        callback = function()
                                            local page_str = jump_dialog:getInputText()
                                            local page_num = tonumber(page_str)
                                            UIManager:close(jump_dialog)
                                            if not page_num or page_num < 1 or page_num > pages then
                                                UIManager:show(InfoMessage:new{ text = T(_("Invalid page number. Please enter 1 - %1"), pages) })
                                                return
                                            end
                                            -- Override start page
                                            local original_pages_read = chapter.pagesRead
                                            chapter.pagesRead = page_num - 1
                                            self:launchKavitaChapterViewer(chapter, self.catalog_title or self.current_server_name, false)
                                            chapter.pagesRead = original_pages_read
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(jump_dialog)
                        jump_dialog:onShowKeyboard()
                    end,
                },
            })
        end

        -- Add "Mark as read" option
        table.insert(buttons, {})  -- separator
        table.insert(buttons, {
            {
                text = "\u{2713} " .. _("Mark as read"),
                callback = function()
                    UIManager:close(dialog)
                    -- Mark as read by reporting the last page as progress
                    local progress = {
                        volumeId  = chapter.volumeId,
                        chapterId = chapter.id,
                        pageNum   = pages + 1,  -- i lost the thread on page numbers so lets overshoot
                        seriesId  = self.current_series_id,
                        libraryId = self.current_series_library_id,
                    }
                    local code = KavitaClient:postReaderProgress(progress)
                    if code == 200 or code == 204 then
                        UIManager:show(InfoMessage:new{ text = _("Marked as read") })
                        -- Refresh the current view to update progress indicators
                        self:refreshCurrentView()
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to mark as read") })
                    end
                end,
            },
        })

        do
            local cache_key = self:_serverKeyForCurrent()
            if cache_key and not self:_store():has_meta(cache_key, self.current_series_id, chapter.id) then
                table.insert(buttons, {})
                table.insert(buttons, {
                    {
                        text = "\u{2913} " .. _("Download chapter"),
                        callback = function()
                            UIManager:close(dialog)
                            local bytes = 0
                            for _, f in ipairs(chapter.files or {}) do
                                bytes = bytes + (tonumber(f.bytes) or 0)
                            end
                            self:_confirmAndEnqueue(self:_cacheEntriesFor({
                                {
                                    id = chapter.id, volumeId = chapter.volumeId,
                                    number = chapter.number,
                                    title = Utils.buildChapterTitle(chapter),
                                    pages = pages, order = chapter.order,
                                    bytes = bytes, pagesRead = chapter.pagesRead,
                                    koreaderHash = chapter.files and chapter.files[1]
                                        and chapter.files[1].koreaderHash,
                                    files = chapter.files,
                                },
                            }))
                        end,
                    },
                })
            end
        end

        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    -- Handle volume long-press for reading options
    if item.kavita_volume and item.volume and item.volume.id then
        local vol = item.volume
        local ch = (type(vol.chapters) == "table") and vol.chapters[1] or nil
        if not ch or not ch.id then
            UIManager:show(InfoMessage:new{ text = _("This volume has no chapters available.") })
            return true
        end

        local pages = ch.pages or (ch.files and #ch.files) or 0
        if pages <= 0 then
            UIManager:show(InfoMessage:new{ text = _("This volume has no pages to display") })
            return true
        end

        local dialog
        local buttons = {
            {
                {
                    text = "\u{2194} " .. _("Page mode"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Launch in page mode (view_mode=0), continue from last position
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true, 0)
                    end,
                },
                {
                    text = "\u{2195} " .. _("Continuous"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Launch in continuous mode (view_mode=1), continue from last position
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true, 1)
                    end,
                },
            },
            {},  -- separator
            {
                {
                    text = "\u{23EE} " .. _("From start"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Override start page to 1
                        local original_pages_read = ch.pagesRead
                        ch.pagesRead = 0
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
                        ch.pagesRead = original_pages_read
                    end,
                },
                {
                    text = _("Continue") .. " \u{25B6}",
                    callback = function()
                        UIManager:close(dialog)
                        -- Use normal behavior (resume from pagesRead)
                        self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
                    end,
                },
            },
        }

        -- Add "Jump to" option if there are pages to jump to
        if pages > 1 then
            table.insert(buttons, {
                {
                    text = _("Jump to page") .. " \u{23E9}",
                    callback = function()
                        UIManager:close(dialog)
                        local jump_dialog
                        jump_dialog = InputDialog:new{
                            title = _("Jump to page"),
                            input_hint = T(_("1 - %1"), pages),
                            input_type = "number",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(jump_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Jump"),
                                        is_enter_default = true,
                                        callback = function()
                                            local page_str = jump_dialog:getInputText()
                                            local page_num = tonumber(page_str)
                                            UIManager:close(jump_dialog)
                                            if not page_num or page_num < 1 or page_num > pages then
                                                UIManager:show(InfoMessage:new{ text = T(_("Invalid page number. Please enter 1 - %1"), pages) })
                                                return
                                            end
                                            -- Override start page
                                            local original_pages_read = ch.pagesRead
                                            ch.pagesRead = page_num - 1
                                            self:launchKavitaChapterViewer(ch, self.catalog_title or self.current_server_name, true)
                                            ch.pagesRead = original_pages_read
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(jump_dialog)
                        jump_dialog:onShowKeyboard()
                    end,
                },
            })
        end

        -- Add "Mark as read" option
        table.insert(buttons, {})  -- separator
        table.insert(buttons, {
            {
                text = "\u{2713} " .. _("Mark as read"),
                callback = function()
                    UIManager:close(dialog)
                    -- Mark as read by reporting the last page as progress
                    local progress = {
                        volumeId  = ch.volumeId,
                        chapterId = ch.id,
                        pageNum   = pages,  -- i lost the thread on page numbers so lets overshoot
                        seriesId  = self.current_series_id,
                        libraryId = self.current_series_library_id,
                    }
                    local code = KavitaClient:postReaderProgress(progress)
                    if code == 200 or code == 204 then
                        UIManager:show(InfoMessage:new{ text = _("Marked as read") })
                        -- Refresh the current view to update progress indicators
                        self:refreshCurrentView()
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to mark as read") })
                    end
                    UIManager:close(dialog)
                end,
            },
        })

        do
            local cache_key = self:_serverKeyForCurrent()
            if cache_key then
                local descriptors = {}
                for _, vch in ipairs(vol.chapters or {}) do
                    local bytes = 0
                    for _, f in ipairs(vch.files or {}) do
                        bytes = bytes + (tonumber(f.bytes) or 0)
                    end
                    descriptors[#descriptors + 1] = {
                        id = vch.id, volumeId = vch.volumeId, number = vch.number,
                        title = Utils.buildChapterTitle(vch), pages = vch.pages,
                        order = vch.order, bytes = bytes, pagesRead = vch.pagesRead,
                        koreaderHash = vch.files and vch.files[1] and vch.files[1].koreaderHash,
                        files = vch.files,
                    }
                end
                local entries = self:_cacheEntriesFor(descriptors)
                if #entries > 0 then
                    table.insert(buttons, {})
                    table.insert(buttons, {
                        {
                            text = "\u{2913} " .. _("Download volume"),
                            callback = function()
                                UIManager:close(dialog)
                                self:_confirmAndEnqueue(entries)
                            end,
                        },
                    })
                end
            end
        end

        dialog = ButtonDialog:new{
            title = item.text,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    -- Handle server (root list) long-press for Edit/Delete
    if #self.paths > 0 then return true end -- not root list
    local dialog
    dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete Kavita server?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                UIManager:close(dialog)
                                self:deleteCatalog(item)
                            end,
                        })
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditServer(item, true)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- Menu action on previous-page chevron tap
function KavitaBrowser:onPrevPage()
    return Menu.onPrevPage(self)
end

-- Menu action on return-arrow tap (go to one-level upper catalog)
function KavitaBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        self.catalog_title = path.title
        self.catalog_author = path.author
        if path.kavita_cache_shelf then
            self:showCacheShelf(true)
        elseif path.kavita_offline_series then
            self:showOfflineSeries({
                _cache_server_key = path.kavita_offline_series.serverKey,
                _cache_series_id = path.kavita_offline_series.seriesId,
                text = path.title,
            })
        elseif path.kavita_orphan_group then
            self:_showOrphanGroup({ text = path.title, _orphan_items = self._orphan_items })
        elseif path.kavita_stream_root then
            -- return to the last stream list
            self:showKavitaStream(
                path.kavita_stream_root,
                path.stream_type,
                path.stream_title,
                path.smart_filter_encoded
            )
        elseif path.kavita_reading_list_root then
            -- return into the open reading list
            self:showReadingListDetail(
                path.kavita_reading_list_root,
                path.reading_list_title or path.title
            )
        elseif path.kavita_reading_lists_root then
            -- return to the reading lists overview
            self:showReadingLists()
        elseif path.kavita_dashboard_root then
            -- return to dashboard for current server
            self:showDashboardAfterSelection(self.current_server_name or self.catalog_title)
        else
            self:init()
        end
    else
        -- return to root path, we simply reinit KavitaBrowser
        self:init()
    end
    return true
end


-- Menu action on return-arrow long-press (return to root path)
function KavitaBrowser:onHoldReturn()
    self:init()
    return true
end

-- Menu action on next-page chevron tap
function KavitaBrowser:onNextPage()
    return Menu.onNextPage(self)
end

return KavitaBrowser
