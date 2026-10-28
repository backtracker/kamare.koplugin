-- Small pure helpers shared by the cache UI. Kept free of UI requires so the
-- decision logic (start page, read state) is unit-testable.

local Util = {}

function Util.format_bytes(n)
    n = tonumber(n)
    if not n or n <= 0 then return "0 MB" end
    if n >= 1024 * 1024 * 1024 then return string.format("%.1f GB", n / (1024 * 1024 * 1024)) end
    if n >= 1024 * 1024 then return string.format("%.0f MB", n / (1024 * 1024)) end
    return string.format("%.0f KB", n / 1024)
end

function Util.format_duration(seconds, template)
    seconds = math.max(0, tonumber(seconds) or 0)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if template then
        return h > 0 and template(h, m) or template(0, m)
    end
    if h > 0 then return string.format("%d h %d min", h, m) end
    return string.format("%d min", m)
end

local function natural_tokens(value)
    local tokens, s = {}, tostring(value):lower()
    local i = 1
    while i <= #s do
        local j = s:find("%d", i)
        if not j then
            tokens[#tokens + 1] = { str = s:sub(i) }
            break
        end
        if j > i then tokens[#tokens + 1] = { str = s:sub(i, j - 1) } end
        local k = s:find("%D", j) or (#s + 1)
        tokens[#tokens + 1] = { num = tonumber(s:sub(j, k - 1)) }
        i = k
    end
    return tokens
end

--- Natural, case-insensitive order ("CLAYMORE (2)" before "CLAYMORE (10)").
function Util.natural_compare(a, b)
    a, b = tostring(a), tostring(b)
    local ta, tb = natural_tokens(a), natural_tokens(b)
    for i = 1, math.max(#ta, #tb) do
        local x, y = ta[i], tb[i]
        if not x then return true end
        if not y then return false end
        if x.num ~= nil and y.num ~= nil then
            if x.num ~= y.num then return x.num < y.num end
        elseif x.num ~= nil then
            return true
        elseif y.num ~= nil then
            return false
        elseif x.str ~= y.str then
            return x.str < y.str
        end
    end
    return a < b
end

function Util.append_status(subtitle, status)
    if not status or status == "" then return subtitle end
    if subtitle and subtitle ~= "" then return subtitle .. " · " .. status end
    return status
end

--- Start page for a cached chapter (05 A5): journal > snapshot > 1.
function Util.resolve_start_page(journal_page_num, snapshot, pages)
    pages = math.max(1, tonumber(pages) or 1)
    local pos = tonumber(journal_page_num)
    if pos and pos > 0 then return math.min(pos, pages) end
    local snap = tonumber(snapshot)
    if snap and snap > 0 then return math.min(snap, pages) end
    return 1
end

--- Read predicate used by "delete read chapters" (04 A9, union of sources).
function Util.is_read(local_page_num, snapshot, server_pages_read, pages)
    pages = tonumber(pages)
    if not pages or pages <= 0 then return false end
    -- Explicit indexing: ipairs() would stop at a nil first value (no local
    -- position yet) and hide server-side progress.
    local values = { local_page_num, server_pages_read, snapshot }
    for i = 1, 3 do
        local n = tonumber(values[i])
        if n and n >= pages then return true end
    end
    return false
end

return Util
