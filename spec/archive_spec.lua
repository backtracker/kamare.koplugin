local Archive = require("kamarecachearchive")

local function write(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir .. "'") end
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function read(path)
    local f = assert(io.open(path, "rb"))
    local d = f:read("*a")
    f:close()
    return d
end

local function plan_dest_for(plan, path)
    for _, item in ipairs(plan) do
        if item.path == path then return item.dest_name end
    end
end

local function page_of(plan, path)
    for _, item in ipairs(plan) do
        if item.path == path then return item.page end
    end
    return nil
end

return function(t)
    -- natural ordering
    local list = { "10.jpg", "2.jpg", "1.jpg", "001.jpg" }
    table.sort(list, Archive.natural_compare)
    t.eq(table.concat(list, ","), "001.jpg,1.jpg,2.jpg,10.jpg", "natural sort numeric")

    t.ok(Archive.is_image_path("a/b/001.JPG"), "image path upper ext")
    t.ok(not Archive.is_image_path("__MACOSX/a/001.jpg"), "macosx filtered")
    t.ok(not Archive.is_image_path("a/._001.jpg"), "resource fork filtered")
    t.ok(not Archive.is_image_path("a/notes.txt"), "non image filtered")

    -- flat plan
    local flat, err = Archive.build_plan({ "b.jpg", "a10.jpg", "a2.jpg" })
    t.is_nil(err, "flat plan no error")
    t.eq(#flat, 3, "flat plan size")
    t.eq(page_of(flat, "a2.jpg"), 1, "flat a2 first")
    t.eq(page_of(flat, "a10.jpg"), 2, "flat a10 second")
    t.eq(page_of(flat, "b.jpg"), 3, "flat b third")
    t.eq(plan_dest_for(flat, "a2.jpg"), "0001.jpg", "flat dest name")

    -- nested plan replicates Kavita Flatten + natural sort:
    -- only non-root dirs are renamed; root files keep their names but still
    -- participate in the final natural sort (so they come after 000_* names).
    local paths = {
        "a10.jpg", "b.jpg", "a2.jpg",
        "d2/001.jpg", "d2/002.jpg",
        "d1/001.jpg", "d1/010.jpg", "d1/003.jpg",
        "d1/deep/x.jpg",
    }
    local plan, perr = Archive.build_plan(paths)
    t.is_nil(perr, "nested plan no error")
    t.eq(#plan, 9, "nested plan size")
    local expected = {
        ["d1/001.jpg"] = 1, ["d1/003.jpg"] = 2, ["d1/010.jpg"] = 3,
        ["d1/deep/x.jpg"] = 4,
        ["d2/001.jpg"] = 5, ["d2/002.jpg"] = 6,
        ["a2.jpg"] = 7, ["a10.jpg"] = 8, ["b.jpg"] = 9,
    }
    for path, page in pairs(expected) do
        t.eq(page_of(plan, path), page, "nested page " .. path)
    end

    -- a pass-through directory (only subdirectories) still consumes an index;
    -- this is the shape that used to break real volumes (Kavita names the
    -- first chapter folder 001_*, not 002_*).
    local pt_plan, pt_err, pt_names = Archive.build_plan({
        "CLAYMORE 17/Ch1/001.jpg", "CLAYMORE 17/Ch1/002.jpg",
        "CLAYMORE 17/Ch2/001.jpg",
    })
    t.is_nil(pt_err, "pass-through plan no error")
    t.eq(#pt_plan, 3, "pass-through plan size")
    t.eq(pt_names[1], "001_001.jpg", "pass-through consumes index 0")
    t.eq(pt_names[2], "001_002.jpg", "second file in first chapter")
    t.eq(pt_names[3], "002_001.jpg", "second chapter gets index 2")

    -- explicit empty directories also consume an index
    local empty_plan, empty_err, empty_names = Archive.build_plan(
        { "Ch1/001.jpg" }, { "AAA-Empty", "Ch1" })
    t.is_nil(empty_err, "explicit dirs plan no error")
    t.eq(#empty_plan, 1, "explicit dirs plan size")
    t.eq(empty_names[1], "001_001.jpg", "empty dir consumes index 0")

    -- non-image files inside a directory are counted for the flatten index
    local mixed_plan, mixed_err, mixed_names = Archive.build_plan({
        "d/a.jpg", "d/b.txt", "d/c.jpg",
    })
    t.is_nil(mixed_err, "mixed plan no error")
    t.eq(#mixed_plan, 2, "mixed plan skips non-images")
    t.eq(mixed_names[2], "000_003.jpg", "fileIndex counts non-images")

    -- real archive roundtrip (flat + nested, duplicate basenames)
    local root = t.tmpdir()
    write(root .. "/src/a2.jpg", "PAGE-a2")
    write(root .. "/src/a10.jpg", "PAGE-a10")
    write(root .. "/src/b.jpg", "PAGE-b")
    write(root .. "/src/d1/001.jpg", "PAGE-d1-001")
    write(root .. "/src/d1/003.jpg", "PAGE-d1-003")
    write(root .. "/src/d1/010.jpg", "PAGE-d1-010")
    write(root .. "/src/d1/deep/x.jpg", "PAGE-deep-x")
    write(root .. "/src/d2/001.jpg", "PAGE-d2-001")
    write(root .. "/src/d2/002.jpg", "PAGE-d2-002")
    assert(os.execute("cd '" .. root .. "/src' && zip -qr ../test.cbz a2.jpg a10.jpg b.jpg d1 d2") == 0)
    local zip_path = root .. "/test.cbz"
    t.ok(Archive.validate_magic(zip_path), "zip magic ok")
    write(root .. "/notzip.cbz", "<html>error</html>")
    t.ok(not Archive.validate_magic(root .. "/notzip.cbz"), "html rejected")

    local ap, names = Archive.plan_for_archive(zip_path)
    t.ok(ap and #ap == 9, "plan_for_archive reads real zip")
    t.ok(names and names[1] and names[1]:match("^000_001"), "flattened name captured")

    local dest = root .. "/pages"
    local result, xerr = Archive.extract_chapter{
        archive_path = zip_path,
        dest_dir = dest,
        expected_pages = 9,
        dims_names = names,
    }
    t.ok(result ~= nil, "extract chapter ok: " .. tostring(xerr))
    if result then
        t.eq(result.pages, 9, "extracted page count")
        t.eq(read(dest .. "/0001.jpg"), "PAGE-d1-001", "page 1 bytes")
        t.eq(read(dest .. "/0002.jpg"), "PAGE-d1-003", "page 2 bytes")
        t.eq(read(dest .. "/0003.jpg"), "PAGE-d1-010", "page 3 bytes")
        t.eq(read(dest .. "/0004.jpg"), "PAGE-deep-x", "page 4 bytes")
        t.eq(read(dest .. "/0005.jpg"), "PAGE-d2-001", "page 5 bytes")
        t.eq(read(dest .. "/0006.jpg"), "PAGE-d2-002", "page 6 bytes")
        t.eq(read(dest .. "/0007.jpg"), "PAGE-a2", "page 7 bytes")
        t.eq(read(dest .. "/0008.jpg"), "PAGE-a10", "page 8 bytes")
        t.eq(read(dest .. "/0009.jpg"), "PAGE-b", "page 9 bytes")
        t.eq(result.pagesBytes, 87, "pages bytes summed")
    end

    -- wrong page count fails
    local bad, bad_err = Archive.extract_chapter{
        archive_path = zip_path, dest_dir = dest .. "2", expected_pages = 8,
    }
    t.is_nil(bad, "wrong page count rejected")
    t.ok(bad_err and bad_err:find("page count", 1, true) ~= nil, "page count error message")

    -- wrong dims order fails
    local wrong_names = {}
    for i = #names, 1, -1 do wrong_names[#wrong_names + 1] = names[i] end
    local bad2, bad2_err = Archive.extract_chapter{
        archive_path = zip_path, dest_dir = dest .. "3", expected_pages = 9, dims_names = wrong_names,
    }
    t.is_nil(bad2, "page order mismatch rejected")
    t.ok(bad2_err and bad2_err:find("page order", 1, true) ~= nil, "page order error message")

    -- sequential extraction must not reopen once per page
    local archiver = require("ffi/archiver")
    local opens = 0
    local original_open = archiver.Reader.open
    archiver.Reader.open = function(self, path)
        opens = opens + 1
        return original_open(self, path)
    end
    local ok3 = Archive.extract_chapter{
        archive_path = zip_path, dest_dir = dest .. "4", expected_pages = 9,
    }
    archiver.Reader.open = original_open
    t.ok(ok3 ~= nil, "second extraction ok")
    t.ok(opens <= 2, "sequential extraction opens archive at most twice (got " .. opens .. ")")
end
