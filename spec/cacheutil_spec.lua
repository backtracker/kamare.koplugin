local Util = require("kamarecacheutil")

return function(t)
    -- start page priority (acceptance B5/B6). The journal holds Kavita's
    -- 0-based pageNum, so a recorded 53 resumes on page 54 (regression: the
    -- 0.10 viewer wrote 0-based and the resume path read it as 1-based).
    t.eq(Util.resolve_start_page(60, 30, 194), 61, "journal wins over snapshot")
    t.eq(Util.resolve_start_page(53, nil, 196), 54, "0-based journal page resumes one page later")
    t.eq(Util.resolve_start_page(0, nil, 196), 1, "page 0 is the first page")
    t.eq(Util.resolve_start_page(nil, 30, 194), 30, "snapshot fallback")
    t.eq(Util.resolve_start_page(nil, nil, 194), 1, "no record starts at 1")
    t.eq(Util.resolve_start_page(999, nil, 194), 194, "journal clamped to page count")
    t.eq(Util.resolve_start_page(195, nil, 196), 196, "last page stays the last page")
    t.eq(Util.resolve_start_page(0, 0, 0), 1, "degenerate input")

    -- read union (acceptance D6)
    t.ok(Util.is_read(100, 0, 0, 100), "local journal counts as read")
    t.ok(Util.is_read(0, 0, 100, 100), "server pagesRead counts as read")
    t.ok(Util.is_read(0, 100, 0, 100), "cached snapshot counts as read")
    t.ok(not Util.is_read(50, 0, 50, 100), "partially read is not read")
    t.ok(Util.is_read(nil, nil, 100, 100), "server progress counts when local is nil")
    t.ok(Util.is_read(nil, 100, nil, 100), "snapshot counts when local is nil")
    t.ok(not Util.is_read(nil, nil, 99, 100), "server below total is not read")
    t.ok(not Util.is_read(nil, nil, nil, 100), "no progress is not read")
    t.ok(not Util.is_read(100, 0, 0, nil), "missing page count is not read")

    -- formatting
    t.eq(Util.format_bytes(0), "0 MB", "zero bytes")
    t.eq(Util.format_bytes(1536), "2 KB", "kilobytes")
    t.eq(Util.format_bytes(5 * 1024 * 1024), "5 MB", "megabytes")
    t.eq(Util.format_bytes(3.5 * 1024 * 1024 * 1024), "3.5 GB", "gigabytes")
    t.eq(Util.format_duration(59 * 60), "59 min", "minutes")
    t.eq(Util.format_duration(2 * 3600 + 13 * 60), "2 h 13 min", "hours and minutes")
    t.eq(Util.append_status("12/194 pages", "Cached"), "12/194 pages · Cached", "status appended")
    t.eq(Util.append_status(nil, "Cached"), "Cached", "status alone")
    t.eq(Util.append_status("x", nil), "x", "no status")
end
