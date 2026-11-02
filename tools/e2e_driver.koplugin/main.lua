-- End-to-end driver for the pager takeover (temporary; not part of the plugin).
--
-- It opens a real cached chapter through the public cache API, injects a fake
-- evdev layer at the PagerInput seam (the SDL emulator has no
-- Device.input:open, so a real /dev/input node cannot be used there), and then
-- drives presses through the *real* hook -> dispatch -> guard -> viewer chain,
-- asserting that the page counter actually advances. Screenshots and a result
-- file land in /tmp/opencode/e2e/.
--
-- Usage:
--   cp -r tools/e2e_driver.koplugin ~/koreader-data/plugins/zz_kamare_e2e.koplugin
--   SDL_VIDEODRIVER=x11 kk --kamare src
--   # ... then remove ~/koreader-data/plugins/zz_kamare_e2e.koplugin
--
-- It needs at least one fully cached chapter (state = "complete") for the
-- configured Kavita server; it picks the first one it finds.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Key = require("device/key")
local Device = require("device")
local DataStorage = require("datastorage")
local logger = require("logger")

local OUT = "/tmp/opencode/e2e"
local FAKE_FD = 977
local PROC = [[
I: Bus=0005 Vendor=0000 Product=0000 Version=0000
N: Name="KHP Keyboard"
P: Phys=00:11:22:33:44:55
S: Sysfs=/devices/virtual/input/input9
U: Uniq=
H: Handlers=sysrq kbd event20
B: PROP=0
B: EV=120013
B: KEY=200000000000 0

]]

local E2E = WidgetContainer:extend{ name = "zz_kamare_e2e" }

local results = {}
local function note(key, value)
    results[key] = value
    print("[e2e] " .. key .. " = " .. tostring(value))
end

local function shot(name)
    local path = OUT .. "/" .. name .. ".png"
    local ok, err = pcall(function() Device.screen:shot(path) end)
    if not ok then note("shot_error_" .. name, tostring(err)) end
    return path
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(require("json").decode, text)
    if ok then return data end
    return nil
end

local function pick_chapter()
    local Settings = require("luasettings"):open(DataStorage:getSettingsDir() .. "/kamare.lua")
    local list = Settings:readSetting("servers") or {}
    local server = list[1]
    if not server then return nil end
    local cache = DataStorage:getDataDir() .. "/kamare/cache/" .. tostring(server.key)
    local index = read_json(cache .. "/index.json")
    local chapters = index and index.chapters or {}
    for __, entry in ipairs(chapters) do
        if entry.state == "complete" then
            return {
                base_url = server.url or server.kavita_url,
                api_key = server.api_key,
                entry = { chapterId = entry.chapterId, seriesId = entry.seriesId },
                title = entry.chapterTitle,
            }
        end
    end
    return nil
end

local function inject_fake_input()
    local PagerInput = require("kamarepager_input")
    local fake = {
        event_map = {},
        opened_devices = {},
        links = {},
        opens = 0,
    }
    function fake.open(self, path, name)
        fake.opens = fake.opens + 1
        fake.opened_devices[path] = FAKE_FD
        fake.links[FAKE_FD] = path
        return FAKE_FD
    end
    function fake.close(self, path)
        fake.opened_devices[path] = nil
        fake.links[FAKE_FD] = nil
        return true
    end
    function fake.handleKeyBoardEv(self, ev) return { passed = ev } end

    PagerInput.set_deps{
        device = { input = fake },
        input = fake,
        read_proc = function() return PROC end,
        readlink = function(fd) return fake.links[fd] end,
    }
    PagerInput.attach()
    note("fake_opens", fake.opens)
    note("devices", #PagerInput.devices())
    note("pager_state", require("kamarepager").status().state)
    return fake
end

local fake

local function viewer()
    local ok, module = pcall(require, "kamareimageviewer")
    return ok and module.active_instance or nil
end

local function page()
    local v = viewer()
    return v and v._images_list_cur or nil
end

local function pager_press(code)
    return fake.handleKeyBoardEv(fake, { fd = FAKE_FD, code = code, value = 1 })
end

local steps = {}

local function step(fn, delay)
    steps[#steps + 1] = { fn = fn, delay = delay }
end

local function run_next()
    local s = table.remove(steps, 1)
    if not s then return end
    UIManager:scheduleIn(s.delay or 1, function()
        local ok, err = pcall(s.fn)
        if not ok then note("step_error", tostring(err)) end
        run_next()
    end)
end

function E2E:init()
    UIManager:scheduleIn(3, function()
        local ok, err = pcall(function()
            fake = inject_fake_input()

            local chapter = pick_chapter()
            if not chapter then error("no cached chapter found") end
            note("chapter", chapter.title)
            note("base_url", chapter.base_url)

            local Cache = require("kamarecache")
            local viewer_obj, code, message = Cache.open{
                base_url = chapter.base_url,
                api_key = chapter.api_key,
                entry = chapter.entry,
                start_page = 100,
            }
            note("open_code", code or "ok")
            note("open_message", message)
        end)
        if not ok then note("open_error", tostring(err)) end
        run_next()
    end)

    -- wait for the viewer
    step(function() end, 4)
    step(function()
        local v = viewer()
        note("viewer_open", v ~= nil)
        note("page_start", page())
        shot("e2e-01-open")
    end, 2)

    -- 1) pager press through the real hook
    step(function()
        local before = page()
        local consumed = pager_press(109)
        note("press1_consumed", consumed == nil)
        note("press1_before", before)
        note("press1_after", page())
        note("press1_advanced", page() == (before or 0) + 1)
    end, 2)
    step(function() shot("e2e-02-next") end, 1)

    -- 2) two presses back-to-back: the dedupe window must swallow the second
    step(function()
        local before = page()
        pager_press(109)
        local after_first = page()
        pager_press(109)
        note("dedupe_before", before)
        note("dedupe_after_first", after_first)
        note("dedupe_first_advanced", after_first == (before or 0) + 1)
        note("dedupe_second_swallowed", page() == after_first)
    end, 1)

    -- 3) after the window, a press turns again
    step(function()
        local before = page()
        UIManager:scheduleIn(0.6, function()
            pager_press(109)
            note("press3_before", before)
            note("press3_after", page())
            note("press3_advanced", page() == (before or 0) + 1)
        end)
    end, 1.5)
    step(function() shot("e2e-03-next") end, 1)

    -- 4) GotoViewRel (what ko-pageturner broadcasts when it swallows the key)
    step(function()
        local before = page()
        UIManager:sendEvent(Event:new("GotoViewRel", 1))
        note("gotoviewrel_before", before)
        note("gotoviewrel_after", page())
        note("gotoviewrel_advanced", page() == (before or 0) + 1)
    end, 2)
    step(function() shot("e2e-04-gotoviewrel") end, 1)

    -- 5) a native KeyPress that the viewer's key_events handle
    step(function()
        local before = page()
        UIManager:sendEvent(Event:new("KeyPress", Key:new("LPgFwd", {})))
        note("keypress_before", before)
        note("keypress_after", page())
        note("keypress_advanced", page() == (before or 0) + 1)
    end, 2)
    step(function() shot("e2e-05-keypress") end, 1)

    -- 6) previous page through the pager
    step(function()
        local before = page()
        pager_press(104)
        note("prev_before", before)
        note("prev_after", page())
        note("prev_moved", page() == (before or 0) - 1)
    end, 2)

    step(function()
        local out = io.open(OUT .. "/result.txt", "w")
        if out then
            local keys = {}
            for k in pairs(results) do keys[#keys + 1] = k end
            table.sort(keys)
            for __, k in ipairs(keys) do
                out:write(k, " = ", tostring(results[k]), "\n")
            end
            out:close()
        end
        shot("e2e-06-final")
    end, 1)

    step(function()
        UIManager:quit()
    end, 2)
end

return E2E
