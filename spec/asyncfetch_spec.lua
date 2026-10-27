local AsyncFetch = require("kamareasyncfetch")

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function split(s, sep)
    local out = {}
    for part in tostring(s):gmatch("([^" .. sep .. "]+)") do out[#out + 1] = part end
    return out
end

local function start_server(t, root)
    local portfile = root .. "/port.txt"
    local repo = t.spec_dir
    local py = repo .. "/fixtures/range_server.py"
    os.execute(string.format("python3 '%s' '%s' '%s' >/dev/null 2>&1 &", py, root, portfile))
    for _ = 1, 100 do
        local data = read(portfile)
        if data then return data end
        os.execute("sleep 0.05")
    end
    return nil
end

return function(t)
    local root = t.tmpdir()
    local payload = {}
    for i = 1, 3000 do
        payload[i] = string.format("%04d-%s\n", i, string.rep(string.char(65 + (i % 26)), 95))
    end
    local data = table.concat(payload)
    write(root .. "/file.bin", data)
    write(root .. "/norange.bin", data)
    write(root .. "/chunked.bin", data)

    local info = start_server(t, root)
    if not info then
        t.fail("fixture server did not start")
        return
    end
    local lines = split(info, "\n")
    local port, pid = tonumber(lines[1]), lines[2]
    local base = "http://127.0.0.1:" .. port

    local function cleanup()
        if pid then os.execute("kill " .. pid .. " >/dev/null 2>&1") end
    end

    local function run_fetch(req, opts, label)
        local done, result = false, nil
        local queue = {}
        local scheduler = {
            scheduleIn = function(_, _, fn) queue[#queue + 1] = fn end,
        }
        opts.scheduler = scheduler
        AsyncFetch.fetch(req, opts, function(body, code, stats)
            done = true
            result = { body = body, code = code, stats = stats }
        end)
        local guard = 0
        while not done and guard < 200000 do
            local fn = table.remove(queue, 1)
            if not fn then break end
            fn()
            guard = guard + 1
        end
        if not done then
            t.fail(label .. " did not complete")
            return nil
        end
        return result
    end

    -- full download to a file sink
    local sink = root .. "/out.bin"
    local r = run_fetch({ url = base .. "/file.bin", method = "GET", headers = {} }, {
        sink_path = sink, total_timeout = 60, quantum_ms = 60,
    }, "full fetch")
    t.ok(r and r.code == 200, "full fetch 200")
    t.eq(r and r.stats.bytes, #data, "stats bytes == content length")
    t.ok(r and r.body == nil, "sink fetch returns no in-memory body")
    t.ok(read(sink) == data, "sink file matches payload")

    -- byte progress callback fires while streaming to disk
    local progress
    local rp = run_fetch({ url = base .. "/file.bin", method = "GET", headers = {} }, {
        sink_path = root .. "/progress.bin", total_timeout = 60, quantum_ms = 60,
        on_progress = function(bytes, total)
            progress = { bytes = bytes, total = total }
        end,
    }, "progress fetch")
    t.ok(rp and rp.code == 200, "progress fetch 200")
    t.ok(progress ~= nil, "on_progress called")
    t.ok(progress and progress.bytes > 0, "on_progress reports bytes")
    t.eq(progress and progress.total, #data, "on_progress knows content length")

    -- existing in-memory behaviour is untouched
    local r0 = run_fetch({ url = base .. "/file.bin", method = "GET", headers = {} }, {
        total_timeout = 60,
    }, "memory fetch")
    t.ok(r0 and r0.code == 200 and r0.body == data, "non-sink fetch still returns the body")

    -- resume with Range from an existing prefix
    local part = root .. "/resume.bin"
    write(part, data:sub(1, 100000))
    local r2 = run_fetch({ url = base .. "/file.bin", method = "GET", headers = {} }, {
        sink_path = part, sink_offset = 100000, total_timeout = 60,
    }, "resume fetch")
    t.eq(r2 and r2.code, 206, "resume got 206")
    t.ok(read(part) == data, "resume appends correct bytes")

    -- server that ignores Range: caller is told to restart
    local part2 = root .. "/norange.bin.part"
    write(part2, data:sub(1, 500))
    local r3 = run_fetch({ url = base .. "/norange.bin", method = "GET", headers = {} }, {
        sink_path = part2, sink_offset = 500, total_timeout = 60,
    }, "norange fetch")
    t.ok(r3 and r3.code == 200, "norange got 200")
    t.ok(read(part2) ~= nil, "norange leaves a file for caller to truncate")

    -- chunked body streamed to disk
    local chunk_sink = root .. "/chunked.bin.out"
    local r4 = run_fetch({ url = base .. "/chunked.bin", method = "GET", headers = {} }, {
        sink_path = chunk_sink, total_timeout = 60,
    }, "chunked fetch")
    t.ok(r4 and r4.code == 200, "chunked fetch 200")
    t.ok(read(chunk_sink) == data, "chunked sink matches payload")

    -- page priority counter + download yield hook
    t.eq(AsyncFetch.page_requests_inflight(), 0, "no page requests initially")
    local pause_calls = 0
    local done, code = false, nil
    local queue = {}
    local scheduler = { scheduleIn = function(_, _, fn) queue[#queue + 1] = fn end }
    AsyncFetch.fetch({ url = base .. "/file.bin", method = "GET", headers = {} }, {
        sink_path = root .. "/pause.bin",
        scheduler = scheduler,
        priority = "download",
        pause_when = function()
            pause_calls = pause_calls + 1
            return pause_calls < 2
        end,
        total_timeout = 60,
    }, function(_, c) done = true; code = c end)
    t.eq(AsyncFetch.page_requests_inflight(), 0, "download does not count as page request")
    local guard = 0
    while not done and guard < 200000 do
        local fn = table.remove(queue, 1)
        if not fn then break end
        fn()
        guard = guard + 1
    end
    t.ok(done and code == 200, "download completes after yielding")
    t.ok(pause_calls >= 2, "pause hook was honoured")
    t.ok(read(root .. "/pause.bin") == data, "yielded download is intact")

    -- page-priority counter is visible to the queue while in flight
    local page_done = false
    local pq = {}
    AsyncFetch.fetch({ url = base .. "/file.bin", method = "GET", headers = {} }, {
        sink_path = root .. "/page.bin",
        scheduler = { scheduleIn = function(_, _, fn) pq[#pq + 1] = fn end },
        priority = "page",
        total_timeout = 60,
    }, function() page_done = true end)
    t.eq(AsyncFetch.page_requests_inflight(), 1, "page request counted while in flight")
    guard = 0
    while not page_done and guard < 200000 do
        local fn = table.remove(pq, 1)
        if not fn then break end
        fn()
        guard = guard + 1
    end
    t.eq(AsyncFetch.page_requests_inflight(), 0, "page counter released after completion")

    cleanup()
end
