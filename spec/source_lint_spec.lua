-- Source lint: gettext `_()` must never be shadowed by a throwaway loop/local
-- variable. This exact bug crashed real series/shelf views (Lua lexical scope
-- made `_(...)` call the loop index). We use `__` for throwaways everywhere.
local lfs = require("libs/libkoreader-lfs")

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function check_methods(t, source, class, allowed, label)
    local defined = {}
    for name in source:gmatch("function " .. class .. ":([%w_]+)") do defined[name] = true end
    for name in source:gmatch("self%.([%w_]+)%s*=%s*function") do defined[name] = true end
    for name in source:gmatch("self:([%w_]+)%s*%(") do
        if not defined[name] and not allowed[name] then
            t.fail(label .. ": self:" .. name .. "() is not defined on " .. class)
        end
    end
end

return function(t)
    local src = t.spec_dir .. "/../src"
    local checked = 0
    for name in lfs.dir(src) do
        if name:match("%.lua$") then
            local source = read(src .. "/" .. name)
            local uses_gettext = source and (source:find('require("gettext")', 1, true)
                or source:find("local _ = GetText", 1, true))
            if uses_gettext then
                checked = checked + 1
                t.ok(not source:find("for _, ", 1, true),
                    name .. ": use `for __,` (do not shadow gettext _)")
                t.ok(not source:find("local _,", 1, true),
                    name .. ": use `local __,` (do not shadow gettext _)")
            end
        end
    end
    t.ok(checked > 0, "lint checked gettext-using files")

    -- Method-name typos in the two big UI classes (a snake_case slip shipped
    -- once and crashed the chapter long-press menu). Menu/Widget methods are
    -- inherited, so allow the few that are actually used.
    check_methods(t, read(src .. "/kavitabrowser.lua"), "KavitaBrowser", {
        setTitleBarLeftIcon = true,
        switchItemTable = true,
    }, "kavitabrowser")
    check_methods(t, read(src .. "/kamareimageviewer.lua"), "KamareImageViewer", {
        registerTouchZones = true,
    }, "kamareimageviewer")

    -- The next-chapter callback must only fire from `_closeAndNotifyNextChapter`,
    -- i.e. after the viewer closed and on the next tick. Calling it inline made
    -- a caller that opens the next chapter (Moon's cache adapter) hit the
    -- singleton guard and fail with `viewer_running`.
    local viewer_source = read(src .. "/kamareimageviewer.lua") or ""
    t.ok(viewer_source:find("function KamareImageViewer:_closeAndNotifyNextChapter", 1, true) ~= nil,
        "kamareimageviewer: next-chapter hand-off goes through _closeAndNotifyNextChapter")
    local direct_calls = select(2, viewer_source:gsub("on_next_chapter_callback%s*%(", ""))
    t.eq(direct_calls, 0,
        "kamareimageviewer: do not call the next-chapter callback inline (close the viewer first)")
end
