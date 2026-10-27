local GetText = require("gettext")

-- Load the plugin's own gettext catalog before requiring the modules below.
-- Several of them evaluate translated strings at load time (the settings menu,
-- browser titles, ...), and KOReader only loads the core catalogs itself.
do
    local source = debug.getinfo(1, "S").source
    local plugin_dir = source and source:match("^@(.+)[/\\][^/\\]+$")
    local lang = GetText.current_lang
    if plugin_dir and lang and lang ~= "C" then
        local langs = { lang }
        if lang == "zh" then
            table.insert(langs, "zh_CN")
        end
        for __, code in ipairs(langs) do
            local mo_path = plugin_dir .. "/l10n/" .. code .. "/kamare.mo"
            local mo_file = io.open(mo_path, "rb")
            if mo_file then
                mo_file:close()
                GetText.loadMO(mo_path)
                break
            end
        end
    end
end

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local KavitaBrowser = require("kavitabrowser")
local KavitaClient = require("kavitaclient")
local logger = require("logger")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local random = require("frontend/random")
local _ = GetText

local Kamare = WidgetContainer:extend{
    name = "kamare",
    kamare_settings_file = DataStorage:getSettingsDir() .. "/kamare.lua",
    kamare_device_id = nil,
    servers = nil,
    has_coverbrowser = false,
    BookInfoManager = nil,
    CoverMenu = nil,
    ListMenu = nil,
    MosaicMenu = nil,
}

function Kamare:init()
    self.kamare_settings = LuaSettings:open(self.kamare_settings_file)

    if next(self.kamare_settings.data) == nil then
        self.updated = true -- first run, force flush
        logger.info("Kamare: first run, initializing settings")
    end

    self.servers = self.kamare_settings:readSetting("servers", {})

    self:_initializeDeviceId()

    -- Set the device ID on KavitaClient
    KavitaClient:setDeviceId(self.kamare_device_id)

    -- Try to load CoverBrowser modules
    self:loadCoverBrowserModules()

    -- Install BookInfoManager hook for Kavita metadata caching
    if self.has_coverbrowser then
        local BookInfoManagerHook = require("bookinfomanagerhook")
        BookInfoManagerHook:install(self)
    end

    -- Footer mode will be loaded by KamareImageViewer instances as needed
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Kamare:loadCoverBrowserModules()
    -- Try loading BookInfoManager
    local ok, module = pcall(require, "bookinfomanager")
    if ok then
        self.BookInfoManager = module
    else
        logger.warn("Kamare: Failed to load bookinfomanager:", module)
    end

    -- Try loading CoverMenu
    ok, module = pcall(require, "covermenu")
    if ok then
        self.CoverMenu = module
    else
        logger.warn("Kamare: Failed to load covermenu:", module)
    end

    -- Try loading ListMenu
    ok, module = pcall(require, "listmenu")
    if ok then
        self.ListMenu = module
    else
        logger.warn("Kamare: Failed to load listmenu:", module)
    end

    -- Try loading MosaicMenu
    ok, module = pcall(require, "mosaicmenu")
    if ok then
        self.MosaicMenu = module
    else
        logger.warn("Kamare: Failed to load mosaicmenu:", module)
    end

    -- Check if all modules loaded successfully
    if self.BookInfoManager and self.CoverMenu and self.ListMenu and self.MosaicMenu then
        self.has_coverbrowser = true
    else
        logger.warn("Kamare: CoverBrowser integration disabled - missing modules:",
                    "BookInfoManager=", self.BookInfoManager ~= nil,
                    "CoverMenu=", self.CoverMenu ~= nil,
                    "ListMenu=", self.ListMenu ~= nil,
                    "MosaicMenu=", self.MosaicMenu ~= nil)
    end
end

function Kamare:onDispatcherRegisterActions()
    Dispatcher:registerAction("kamare_show_catalog",
        {category="none", event="ShowKavitaBrowser", title=_("Kavita Manga Reader"), filemanager=true,}
    )
end

function Kamare:addToMainMenu(menu_items)
    menu_items.kamare = {
        text = _("Kavita Manga Reader"),
        sorting_hint = "search",
        callback = function()
            self:onShowKavitaBrowser()
        end,
    }
end

-- Lazily build the shared cache context: one store, one journal and one
-- download queue for the whole plugin session (spec 05 A10: single writer).
function Kamare:_getCacheContext()
    if self._cache_context then return self._cache_context end
    local Store = require("kamarecachestore")
    local Journal = require("kamarejournal")
    local Queue = require("kamarecachequeue")
    local KavitaClient = require("kavitaclient")

    local store = Store:new{}
    local journal = Journal:new{ scheduler = UIManager }
    journal:load()

    local ui = {
        prevent_standby = function() UIManager:preventStandby() end,
        allow_standby = function() UIManager:allowStandby() end,
        on_state_change = function(status)
            if self.browser and self.browser.onCacheStateChanged then
                self.browser:onCacheStateChanged(status)
            end
        end,
        on_chapter_done = function()
            if self.browser and self.browser.onCacheChapterDone then
                self.browser:onCacheChapterDone()
            end
        end,
    }
    local queue = Queue:new{
        store = store,
        settings = self.kamare_settings,
        client = KavitaClient,
        ui = ui,
    }
    queue:load()

    self._cache_context = { store = store, journal = journal, queue = queue }

    -- Publish the very same instances through the public facade so external
    -- callers share one queue and one writer (spec 05 A10 / 09 A2).
    local Cache = require("kamarecache")
    Cache.set_context(self._cache_context)
    self.cache_api = Cache

    return self._cache_context
end

function Kamare:_syncJournal()
    local ctx = self:_getCacheContext()
    if not NetworkMgr:isOnline() then return end
    local KavitaClient = require("kavitaclient")
    -- Automatic sync is strictly monotonic. The "current book is behind"
    -- exception is handled interactively by the manual Sync action.
    local ok, summary = pcall(ctx.journal.sync, ctx.journal, KavitaClient, {})
    if ok and summary then
        logger.info("[kamare:journal] sync pushed=", summary.pushed,
            "superseded=", summary.superseded, "failed=", summary.failed,
            "skipped=", summary.skipped)
    end
end

function Kamare:_showBrowser(offline)
    local ctx = self:_getCacheContext()
    self.browser = KavitaBrowser:new{
        ui = self.ui,
        servers = self.servers,
        title = _("Kavita Manga Reader"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        kamare_settings = self.kamare_settings,
        cache = ctx,
        offline = offline,
        -- Pass CoverBrowser modules if available
        has_coverbrowser = self.has_coverbrowser,
        BookInfoManager = self.BookInfoManager,
        CoverMenu = self.CoverMenu,
        ListMenu = self.ListMenu,
        MosaicMenu = self.MosaicMenu,
        close_callback = function()
            UIManager:close(self.browser)
        end,
    }

    UIManager:show(self.browser)

    if not offline then
        UIManager:nextTick(function() self:_syncJournal() end)
    end
end

function Kamare:onShowKavitaBrowser()
    -- Offline: go straight to the cached shelf; never prompt to enable Wi-Fi.
    if NetworkMgr:isOnline() == false then
        self:_showBrowser(true)
        return
    end
    NetworkMgr:runWhenConnected(function()
        self:_showBrowser(false)
    end)
end

function Kamare:getSettings()
    return self.kamare_settings
end

function Kamare:saveSettings()
    self.kamare_settings:flush()
    self.updated = nil
end

function Kamare:onFlushSettings()
    -- Always flush to ensure settings persistence
    self:saveSettings()
end

function Kamare:_initializeDeviceId()
    local saved_device_id = self.kamare_settings:readSetting("kamare_device_id")

    if saved_device_id and saved_device_id ~= "" then
        self.kamare_device_id = saved_device_id
    else
        self.kamare_device_id = random.uuid(true)

        self.kamare_settings:saveSetting("kamare_device_id", self.kamare_device_id)
        logger.info("Kamare: Generated new Kamare device ID:", self.kamare_device_id)
    end
end

function Kamare:onSuspend()
    local ctx = self._cache_context
    if ctx then
        pcall(ctx.journal.force_flush, ctx.journal)
    end
end

function Kamare:onNetworkConnected()
    if self.browser then
        self:_syncJournal()
    end
end

function Kamare:onResume()
    if self.browser then
        NetworkMgr:runWhenConnected(function()
            -- WiFi is connected now
            logger.dbg("Kamare: WiFi connected on resume, ready for streaming")
        end)
    end
end

return Kamare
