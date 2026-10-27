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
    for _, value in ipairs({ local_page_num, server_pages_read, snapshot }) do
        local n = tonumber(value)
        if n and n >= pages then return true end
    end
    return false
end

return Util
