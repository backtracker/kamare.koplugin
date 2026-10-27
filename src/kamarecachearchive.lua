--[[--
Chapter archive handling: page-order replication, sequential extraction and
validated downloads.

Kavita derives page order from the extracted archive in two steps:
  1. DirectoryService.Flatten (only when the archive has subdirectories):
     depth-first, and only for **non-root** directories, every file is renamed
     to `{dirIndex:03d}_{fileIndex:03d}{ext}`. `dirIndex` starts at 0 and is
     bumped for every non-root directory -- including pass-through directories
     that contain only subdirectories -- and `fileIndex` counts every file in
     that directory (metadata/non-image files included). Files at the root keep
     their original names.
  2. Pages are ordered by natural sort of the file name without extension.

We replicate that ordering locally, then extract the archive **in archive
order**, writing each entry straight to its final page file name. Extracting in
page order would force a full reopen per page (measured: 1175 reopens, 40 s,
704 MB RSS on a 2494-page chapter).
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Archive = {}

Archive.IMAGE_EXTS = { jpg = true, jpeg = true, png = true, webp = true, gif = true, avif = true }
Archive.MAGIC_ZIP = {
    ["PK\003\004"] = true,
    ["PK\005\006"] = true,
    ["PK\007\008"] = true,
}

local function path_parts(path)
    path = tostring(path):gsub("\\", "/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part ~= "." and part ~= "" then parts[#parts + 1] = part end
    end
    return parts
end

local BLACKLISTED_DIRS = {
    ["__MACOSX"] = true,
    ["@Recently-Snapshot"] = true,
    ["@recycle"] = true,
    [".caltrash"] = true,
    [".yacreaderlibrary"] = true,
}

local function has_blacklisted_dir(path)
    for __, part in ipairs(path_parts(path)) do
        if BLACKLISTED_DIRS[part] then return true end
    end
    return false
end

local function extension(path)
    local base = tostring(path):match("([^/\\]+)$") or tostring(path)
    local ext = base:match("%.([%w]+)$")
    return ext and ext:lower() or nil
end

local function basename_no_ext(path)
    local base = tostring(path):match("([^/\\]+)$") or tostring(path)
    return (base:gsub("%.[^.]+$", ""))
end

local function split_natural(value)
    local tokens = {}
    local s = tostring(value):lower()
    local i = 1
    while i <= #s do
        local j = s:find("%d", i)
        if not j then
            tokens[#tokens + 1] = { str = s:sub(i) }
            break
        end
        if j > i then tokens[#tokens + 1] = { str = s:sub(i, j - 1) } end
        local k = s:find("%D", j) or (#s + 1)
        tokens[#tokens + 1] = { num = tonumber(s:sub(j, k - 1)), raw = s:sub(j, k - 1) }
        i = k
    end
    return tokens
end

--- Natural, case-insensitive comparison (Kavita's NaturalSort).
function Archive.natural_compare(a, b)
    a, b = tostring(a), tostring(b)
    if a == b then return false end
    local ta, tb = split_natural(a), split_natural(b)
    for i = 1, math.max(#ta, #tb) do
        local x, y = ta[i], tb[i]
        if not x then return true end
        if not y then return false end
        if x.num ~= nil and y.num ~= nil then
            if x.num ~= y.num then return x.num < y.num end
            if x.raw ~= y.raw then return x.raw < y.raw end
        elseif x.num ~= nil then
            return true -- digit chunks sort before text chunks (stable choice)
        elseif y.num ~= nil then
            return false
        else
            if x.str ~= y.str then return x.str < y.str end
        end
    end
    return a:lower() < b:lower()
end

function Archive.is_image_path(path)
    local ext = extension(path)
    if not ext or not Archive.IMAGE_EXTS[ext] then return false end
    local base = tostring(path):match("([^/\\]+)$") or ""
    if base:sub(1, 2) == "._" then return false end
    for _, part in ipairs(path_parts(path)) do
        if part == "__MACOSX" then return false end
    end
    return true
end

function Archive.page_extension(path)
    return extension(path) or "jpg"
end

--- Build the page plan, replicating Kavita's page order:
---   1. `DirectoryService.Flatten`: only *non-root* directories are renamed,
---      to `{dirIndex:03d}_{fileIndex:03d}{ext}`. `dirIndex` starts at 0 and is
---      incremented for every non-root directory, including pass-through ones
---      that only contain subdirectories. `fileIndex` counts every file in the
---      directory, images or not. Root files keep their original names.
---   2. Natural sort by file name without extension.
--- `file_paths` must contain every file entry (non-images included);
--- `dir_paths` must contain explicit directory entries.
--- Returns the plan (page order), nil, and a page -> flattened name map.
function Archive.build_plan(file_paths, dir_paths)
    if type(file_paths) ~= "table" then return nil, "no entries" end

    local root = { files = {}, children = {}, child_order = {} }
    local function ensure_child(node, name)
        local child = node.children[name]
        if not child then
            child = { files = {}, children = {}, child_order = {} }
            node.children[name] = child
            node.child_order[#node.child_order + 1] = name
        end
        return child
    end
    local function insert(path, is_dir)
        if has_blacklisted_dir(path) then return end
        local parts = path_parts(path)
        if #parts == 0 then return end
        local node = root
        local last = is_dir and #parts or (#parts - 1)
        for i = 1, last do node = ensure_child(node, parts[i]) end
        if not is_dir then
            node.files[#node.files + 1] = { path = path, name = parts[#parts] }
        end
    end

    for __, path in ipairs(dir_paths or {}) do insert(path, true) end
    for __, path in ipairs(file_paths) do insert(path, false) end

    local flattened = {}
    local dir_index = 0
    local function visit(node, is_root)
        if is_root then
            -- Kavita leaves files at the extraction root untouched.
            for __, f in ipairs(node.files) do
                flattened[#flattened + 1] = { name = f.name, path = f.path }
            end
        else
            local this_index = dir_index
            dir_index = dir_index + 1
            local files = {}
            for __, f in ipairs(node.files) do files[#files + 1] = f end
            table.sort(files, function(a, b)
                return Archive.natural_compare(a.path, b.path)
            end)
            for file_index, f in ipairs(files) do
                local ext = extension(f.path)
                local name = string.format("%03d_%03d", this_index, file_index)
                if ext then name = name .. "." .. ext end
                flattened[#flattened + 1] = { name = name, path = f.path }
            end
        end

        table.sort(node.child_order, Archive.natural_compare)
        for __, child_name in ipairs(node.child_order) do
            visit(node.children[child_name], false)
        end
    end
    visit(root, true)

    local pages = {}
    for __, item in ipairs(flattened) do
        if Archive.is_image_path(item.path) then pages[#pages + 1] = item end
    end
    if #pages == 0 then return nil, "no images in archive" end

    table.sort(pages, function(a, b)
        return Archive.natural_compare(basename_no_ext(a.name), basename_no_ext(b.name))
    end)

    local plan, name_of_page = {}, {}
    for page, item in ipairs(pages) do
        name_of_page[page] = item.name
        plan[#plan + 1] = {
            path = item.path,
            page = page,
            dest_name = string.format("%04d.%s", page, Archive.page_extension(item.path)),
        }
    end
    return plan, nil, name_of_page
end

--- All file and directory entries in the archive (dirs matter for flattening).
function Archive.entry_paths(reader)
    local files, dirs = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            files[#files + 1] = entry.path
        elseif entry.mode == "directory" then
            dirs[#dirs + 1] = entry.path
        end
    end
    return files, dirs
end

function Archive.open(path)
    local archiver = require("ffi/archiver")
    local reader = archiver.Reader:new()
    if not reader:open(path) then
        return nil, reader.err or "open failed"
    end
    return reader
end

function Archive.validate_magic(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local magic = f:read(4)
    f:close()
    return magic ~= nil and Archive.MAGIC_ZIP[magic] == true
end

local function mkdir_p(path)
    local acc = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        if acc == "/" then acc = "/" .. part
        elseif acc == "" then acc = part
        else acc = acc .. "/" .. part end
        local mode = lfs.attributes(acc, "mode")
        if mode == nil then
            local ok, err = lfs.mkdir(acc)
            if not ok then return nil, err end
        elseif mode ~= "directory" then
            return nil, acc .. " is not a directory"
        end
    end
    return true
end

function Archive.clear_dir(path)
    local attr = lfs.attributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return nil, "not a directory" end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local cattr = lfs.attributes(child)
            if cattr and cattr.mode == "directory" then
                Archive.clear_dir(child)
                lfs.rmdir(child)
            else
                os.remove(child)
            end
        end
    end
    return true
end

--- Extract `plan` sequentially, in archive order. `reader` must be open.
function Archive.extract(reader, plan, dest_dir)
    local by_path = {}
    for _, item in ipairs(plan) do by_path[item.path] = item end

    local ok, err = Archive.clear_dir(dest_dir)
    if not ok then return nil, err end
    local mok, merr = mkdir_p(dest_dir)
    if not mok then return nil, "mkdir " .. tostring(dest_dir) .. ": " .. tostring(merr) end

    local pages_bytes, pages = 0, 0
    for entry in reader:iterate() do
        local item = entry.mode == "file" and by_path[entry.path]
        if item then
            local dest = dest_dir .. "/" .. item.dest_name
            local eok, eerr = reader:extractToPath(entry.path, dest)
            if not eok then
                return nil, string.format("extract %s: %s", entry.path, tostring(eerr or reader.err))
            end
            local attr = lfs.attributes(dest)
            if not attr or attr.mode ~= "file" or (entry.size and attr.size ~= entry.size) then
                return nil, "extracted size mismatch for " .. entry.path
            end
            pages_bytes = pages_bytes + attr.size
            pages = pages + 1
        end
    end
    if pages ~= #plan then
        return nil, string.format("extracted %d/%d pages", pages, #plan)
    end
    return { pages = pages, pagesBytes = pages_bytes }
end

-- Returns plan, flattened_name_by_page, err.
function Archive.plan_for_archive(path)
    local reader, err = Archive.open(path)
    if not reader then return nil, nil, err end
    local paths, dirs = Archive.entry_paths(reader)
    reader:close(false)
    local plan, perr, names = Archive.build_plan(paths, dirs)
    if not plan then return nil, nil, perr end
    return plan, names
end

local function normalize_page_name(name)
    if type(name) ~= "string" then return nil end
    local base = name:match("([^/\\]+)$") or name
    local ext = extension(base)
    if ext and Archive.IMAGE_EXTS[ext] then
        base = base:sub(1, #base - #ext - 1)
    end
    return base:lower()
end

--- Compare Kavita's file-dimensions fileName list with our page order.
--- Returns true when identical (ignoring directory prefixes/extension case).
function Archive.names_match(plan, dims_names, name_of_page)
    if type(dims_names) ~= "table" or #dims_names ~= #plan then
        logger.warn("[kamare:archive] page count mismatch: ours", #plan,
            "kavita", type(dims_names) == "table" and #dims_names or 0)
        return false
    end
    for i = 1, #plan do
        local expected = normalize_page_name(name_of_page and name_of_page[i] or plan[i].dest_name)
        local actual = normalize_page_name(dims_names[i])
        if not expected or not actual or expected ~= actual then
            -- Tolerate servers that report page files by their final page index.
            local page_num = tostring(plan[i].page)
            local actual_num = actual and actual:match("(%d+)%s*$")
            if not (actual_num and tonumber(actual_num) == tonumber(page_num)) then
                logger.warn("[kamare:archive] page order mismatch at page", i,
                    "ours:", tostring(expected), "kavita:", tostring(actual),
                    "entry:", tostring(plan[i].path))
                return false
            end
        end
    end
    return true
end

--- Extract a whole chapter and validate it.
--- opts = { archive_path, dest_dir, expected_pages, dims_names }
--- returns { pages, pagesBytes, plan } or nil, err
function Archive.extract_chapter(opts)
    local path = opts.archive_path
    local reader, err = Archive.open(path)
    if not reader then return nil, err end

    local entry_paths, dir_paths = Archive.entry_paths(reader)
    local plan, perr, name_of_page = Archive.build_plan(entry_paths, dir_paths)
    if not plan then
        reader:close(false)
        return nil, perr
    end
    if opts.expected_pages and #plan ~= opts.expected_pages then
        reader:close(false)
        return nil, string.format("page count %d ~= expected %d", #plan, opts.expected_pages)
    end
    if opts.dims_names and not Archive.names_match(plan, opts.dims_names, name_of_page) then
        reader:close(false)
        return nil, "page order mismatch against file-dimensions"
    end

    local result, xerr = Archive.extract(reader, plan, opts.dest_dir)
    reader:close(false)
    if not result then return nil, xerr end
    result.plan = plan
    result.name_of_page = name_of_page
    return result
end

--- Download one chapter archive into `<part_path>`, resuming with Range.
--- opts = { url, headers, part_path, archive_bytes, store, scheduler, pause_when,
---          total_timeout }
--- on_done(ok, err, stats); err == "range-unsupported" means the caller should
--- truncate the part and retry from zero.
function Archive.download_to_part(opts, on_done)
    local part = opts.part_path
    local offset = 0
    if opts.store then offset = opts.store:file_size(part) end
    if opts.archive_bytes and offset >= opts.archive_bytes then
        on_done(true, nil, { bytes = 0 })
        return { cancel = function() end }
    end

    local headers = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if offset > 0 then headers["Range"] = "bytes=" .. offset .. "-" end

    local AsyncFetch = require("kamareasyncfetch")
    return AsyncFetch.fetch({
        url = opts.url,
        method = "GET",
        headers = headers,
    }, {
        sink_path = part,
        sink_offset = offset,
        sink_mode = "write",
        quantum_ms = 60,
        total_timeout = opts.total_timeout or 3600,
        priority = "download",
        scheduler = opts.scheduler,
        pause_when = opts.pause_when,
        -- Report absolute progress (resume offset + newly received bytes).
        on_progress = opts.on_progress and function(bytes)
            opts.on_progress(offset + (tonumber(bytes) or 0), opts.archive_bytes)
        end,
    }, function(_, code, stats)
        if code == 200 and offset > 0 then
            -- Server ignored Range: the bytes from `offset` onwards are not the
            -- continuation we asked for. Caller truncates and retries whole.
            on_done(false, "range-unsupported", stats)
            return
        end
        if code ~= 200 and code ~= 206 then
            on_done(false, "http " .. tostring(code), stats)
            return
        end
        if offset > 0 and code == 206 then
            local range = stats and stats.headers and stats.headers["content-range"]
            if not range or not range:match("^bytes " .. offset .. "%-") then
                on_done(false, "bad content-range", stats)
                return
            end
        end
        local size = opts.store and opts.store:file_size(part) or (stats and stats.bytes) or 0
        if opts.archive_bytes and size ~= opts.archive_bytes then
            on_done(false, string.format("size %d/%d", size, opts.archive_bytes), stats)
            return
        end
        logger.info("[kamare:archive] downloaded", size, "bytes to", part)
        on_done(true, nil, stats)
    end)
end

return Archive
