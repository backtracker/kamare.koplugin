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
end
