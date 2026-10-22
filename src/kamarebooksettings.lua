local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

-- Per-series reading settings, stored in one file next to kamare.lua:
--   { series = { ["42"] = { view_mode = 1, crop_borders = 1, ... } } }
--
-- The viewer flushes after every change because launch paths other than the
-- Kamare browser (e.g. the moon plugin) open their own LuaSettings instance
-- for kamare.lua and never flush it; writing immediately keeps per-book
-- settings alive regardless of who owns the global settings object.
local BookSettings = {}

local function sanitize(value)
    return (tostring(value):gsub("[^%w_-]", "_"))
end

-- Kavita's series id is the stable identity behind a "book": every volume or
-- chapter of one series (including the next-chapter launches) resolves to the
-- same settings. Some launch paths may not know the id, so fall back to the
-- series name (scoped by library) rather than silently dropping the settings.
local function seriesKey(metadata)
    if type(metadata) ~= "table" then return nil end

    local id = metadata.seriesId
    if id ~= nil and id ~= "" then
        return sanitize(id)
    end

    local name = metadata.seriesName or metadata.localizedName or metadata.originalName
    if name == nil or name == "" then return nil end
    local library = metadata.libraryId
    if library == nil or library == "" then library = "0" end
    return "name_" .. sanitize(library) .. "_" .. sanitize(name)
end

local function openStore(dir)
    local path = (dir or DataStorage:getSettingsDir()) .. "/kamare_books.lua"
    return LuaSettings:open(path)
end

function BookSettings.open(metadata, dir)
    local key = seriesKey(metadata)
    if not key then return nil end
    local store = openStore(dir)
    local series = store:readSetting("series", {})
    series[key] = series[key] or {}
    return {
        key = key,
        store = store,
        settings = LuaSettings:wrap(series[key]),
    }
end

function BookSettings.load(book, configurable, prefix)
    if book then
        configurable:loadSettings(book.settings, prefix or "")
    end
end

function BookSettings.save(book, configurable, prefix)
    if not book then return end
    configurable:saveSettings(book.settings, prefix or "")
    book.store:flush()
end

-- Copy of the settings Configurable actually persists (numbers, strings and
-- tables; booleans are not part of Configurable's save/load contract).
-- The viewer compares against this to tell a real user change from the
-- book simply being opened and closed.
function BookSettings.snapshot(configurable)
    local snapshot = {}
    for key, value in pairs(configurable) do
        local value_type = type(value)
        if value_type == "number" or value_type == "string" then
            snapshot[key] = value
        elseif value_type == "table" then
            local copy = {}
            for k, v in pairs(value) do copy[k] = v end
            snapshot[key] = copy
        end
    end
    return snapshot
end

local function sameValue(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function BookSettings.same(snapshot, configurable)
    if not snapshot then return false end
    for key, value in pairs(snapshot) do
        if not sameValue(value, configurable[key]) then return false end
    end
    for key, value in pairs(configurable) do
        local value_type = type(value)
        if (value_type == "number" or value_type == "string" or value_type == "table")
            and snapshot[key] == nil then
            return false
        end
    end
    return true
end

return BookSettings
