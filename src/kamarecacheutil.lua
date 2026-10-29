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
--- The units differ on purpose: `journal_page_num` is the journal's pageNum,
--- i.e. Kavita's 0-based page (0 = first page, `pages` = finished), while
--- `snapshot` is the 1-based pages-read count. Both yield a 1-based page.
function Util.resolve_start_page(journal_page_num, snapshot, pages)
    pages = math.max(1, tonumber(pages) or 1)
    local pos = tonumber(journal_page_num)
    if pos and pos >= 0 then return math.min(pos + 1, pages) end
    local snap = tonumber(snapshot)
    if snap and snap > 0 then return math.min(snap, pages) end
    return 1
end

--- Read predicate used by "delete read chapters" (04 A9, union of sources).
function Util.is_read(local_page_num, snapshot, server_pages_read, pages)    pages = tonumber(pages)
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

--- Decide who owns the position when this device and the server disagree.
---
--- Both numbers are Kavita's 0-based PageNum (`== pages` means finished).
--- `pos.basePage` is the server value this device last confirmed (pushed or adopted).
--- Comparing pages alone cannot tell "I deliberately rewound" from "I am simply
--- behind"; the confirmed base is what separates them:
---
---   page > base              un-pushed reading on this device (offline or in-flight)
---   page == base             at rest: whatever the server says wins
---   page <  base             this device rewound after confirming `base`
---
--- Rejected alternative: order writes by timestamp. The server's `lastModifiedUtc`
--- is trustworthy, but a device that read offline has no server timestamp for its
--- own position, so concurrent "offline forward" vs "online rewind" stays
--- undecidable and the later of the two cannot be known. Falling back to "further
--- wins" for that case is the only rule that never throws away pages read.
---@param pos table|nil journal position ({ pageNum, basePage })
---@param server_page integer server PageNum
---@return "push"|"adopt"|"same" decision, integer page
function Util.resolve_progress(pos, server_page)
    server_page = math.max(0, math.floor(tonumber(server_page) or 0))
    local page = pos and tonumber(pos.pageNum)
    if not page then return "adopt", server_page end
    local base = tonumber(pos.basePage)
    if base == nil then
        -- Journals written before `basePage` existed: keep the historical
        -- monotonic rule (local ahead pushes, behind adopts) so upgrading does
        -- not resurrect positions that were already settled.
        if page > server_page then return "push", page end
        if page < server_page then return "adopt", server_page end
        return "same", page
    end
    if page > base then
        if page >= server_page then return "push", page end
        return "adopt", server_page
    elseif page == base then
        if server_page == page then return "same", page end
        return "adopt", server_page
    end
    -- Rewound after confirming `base`: only push if nobody moved the server since.
    if server_page == base then return "push", page end
    if server_page >= page then return "adopt", server_page end
    return "push", page
end

return Util
