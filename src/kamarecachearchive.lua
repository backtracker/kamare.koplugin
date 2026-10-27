--[[--
Chapter archive handling: page-order replication, sequential extraction and
validated downloads.

Kavita derives page order from the archive contents in two steps:
  1. DirectoryService.Flatten: depth-first walk, files before subdirectories at
     each level, every file renamed to `{dirIndex:03d}_{fileIndex:03d}{ext}`.
     Flat archives (no subdirectories) keep their original names.
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

--- Build the page plan from archive entry paths (in archive order).
--- Returns an array in ARCHIVE ORDER:
---   { path = entry_path, page = 1-based page number, dest_name = "0001.jpg" }
function Archive.build_plan(entry_paths)
    if type(entry_paths) ~= "table" then return nil, "no entries" end

    local entries = {}
    local has_dirs = false
    for _, path in ipairs(entry_paths) do
        if Archive.is_image_path(path) then
            local parts = path_parts(path)
            local item = {
                path = path,
                parts = parts,
                name = parts[#parts],
            }
            entries[#entries + 1] = item
            if #parts > 1 then has_dirs = true end
        end
    end
    if #entries == 0 then return nil, "no images in archive" end

    local flattened -- { {name=..., path=...} }
    if not has_dirs then
        flattened = {}
        for _, item in ipairs(entries) do
            flattened[#flattened + 1] = { name = item.name, path = item.path }
        end
    else
        -- Directory tree, preserving insertion independent ordering later.
        local root = { files = {}, dirs = {}, children = {} }
        for _, item in ipairs(entries) do
            local node = root
            for i = 1, #item.parts - 1 do
                local dir_name = item.parts[i]
                if not node.children[dir_name] then
                    local child = { name = dir_name, files = {}, dirs = {}, children = {} }
                    node.children[dir_name] = child
                    node.dirs[#node.dirs + 1] = dir_name
                end
                node = node.children[dir_name]
            end
            node.files[#node.files + 1] = item
        end

        flattened = {}
        local dir_index = 0
        local function visit(node)
            local this_index = dir_index
            dir_index = dir_index + 1

            local files = {}
            for _, f in ipairs(node.files) do files[#files + 1] = f end
            table.sort(files, function(a, b)
                return Archive.natural_compare(a.path, b.path)
            end)
            for file_index, f in ipairs(files) do
                local ext = extension(f.path)
                local name = string.format("%03d_%03d", this_index, file_index)
                if ext then name = name .. "." .. ext end
                flattened[#flattened + 1] = { name = name, path = f.path }
            end

            table.sort(node.dirs, Archive.natural_compare)
            for _, dir_name in ipairs(node.dirs) do
                visit(node.children[dir_name])
            end
        end
        visit(root)
    end

    table.sort(flattened, function(a, b)
        return Archive.natural_compare(basename_no_ext(a.name), basename_no_ext(b.name))
    end)

    local page_of_path, name_of_page = {}, {}
    for page, item in ipairs(flattened) do
        page_of_path[item.path] = page
        name_of_page[page] = item.name
    end

    local plan = {}
    for _, item in ipairs(entries) do
        local page = page_of_path[item.path]
        if page then
            plan[#plan + 1] = {
                path = item.path,
                page = page,
                dest_name = string.format("%04d.%s", page, Archive.page_extension(item.path)),
            }
        end
    end
    return plan, nil, name_of_page
end

function Archive.entry_paths(reader)
    local paths = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            paths[#paths + 1] = entry.path
        end
    end
    return paths
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
    local paths = Archive.entry_paths(reader)
    reader:close(false)
    local plan, perr, names = Archive.build_plan(paths)
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
    if type(dims_names) ~= "table" or #dims_names ~= #plan then return false end
    for i = 1, #plan do
        local expected = normalize_page_name(name_of_page and name_of_page[i] or plan[i].dest_name)
        local actual = normalize_page_name(dims_names[i])
        if not expected or not actual or expected ~= actual then
            -- Tolerate servers that report page files by their final page index.
            local page_num = tostring(plan[i].page)
            local actual_num = actual and actual:match("(%d+)%s*$")
            if not (actual_num and tonumber(actual_num) == tonumber(page_num)) then
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

    local entry_paths = Archive.entry_paths(reader)
    local plan, perr, name_of_page = Archive.build_plan(entry_paths)
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
