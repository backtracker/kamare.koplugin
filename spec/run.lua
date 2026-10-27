-- Minimal test runner for the Kamare offline-cache specs.
--
-- Runs on the KOReader emulator runtime (real rapidjson / libarchive / lfs),
-- so it exercises the same modules the plugin loads on device. No network.
--
-- Usage: ./spec/run.sh            (see spec/run.sh)
--        ./spec/run.sh store      (only spec files whose name contains "store")

local function dirname(path)
    return path:match("^(.*)[/\\][^/\\]+$")
end

local source = debug.getinfo(1, "S").source
local runner_dir = dirname(source and source:match("^@(.*)$") or "spec/run.lua")
local repo_dir = runner_dir and dirname(runner_dir) or "."

package.path = repo_dir .. "/src/?.lua;" .. runner_dir .. "/?.lua;"
    .. "./?.lua;./frontend/?.lua;./common/?.lua;" .. package.path
package.cpath = "./?.so;./common/?.so;./libs/?.so;" .. package.cpath

-- KOReader environment: ffi.load override + lib naming/paths.
require("setupkoenv")

local lfs = require("libs/libkoreader-lfs")

local tmp_root = string.format("/tmp/opencode/kamare-tests/%d", os.time())
local tmp_seq = 0

local function remove_tree(path)
    local attr = lfs.attributes(path)
    if not attr then return end
    if attr.mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

local function make_tmpdir()
    tmp_seq = tmp_seq + 1
    local path = string.format("%s/%d", tmp_root, tmp_seq)
    local cur = ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. "/" .. part
        if lfs.attributes(cur, "mode") ~= "directory" then
            lfs.mkdir(cur)
        end
    end
    return path
end

local results = { passed = 0, failed = 0, errors = {} }

local function record(ok, label)
    if ok then
        results.passed = results.passed + 1
    else
        results.failed = results.failed + 1
        results.errors[#results.errors + 1] = label
        io.write("  FAIL ", label, "\n")
    end
end

local function fmt(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

local t = {}
function t.ok(value, label)
    record(not not value, label or "expected truthy")
end
function t.eq(actual, expected, label)
    record(actual == expected,
        string.format("%s (expected %s, got %s)", label or "eq", fmt(expected), fmt(actual)))
end
function t.near(actual, expected, tolerance, label)
    record(type(actual) == "number" and math.abs(actual - expected) <= (tolerance or 0.0001),
        string.format("%s (expected ~%s, got %s)", label or "near", fmt(expected), fmt(actual)))
end
function t.is_nil(value, label)
    record(value == nil, string.format("%s (expected nil, got %s)", label or "is_nil", fmt(value)))
end
function t.fail(msg)
    record(false, msg or "fail")
end
function t.tmpdir()
    return make_tmpdir()
end
t.tmp_root = tmp_root
t.spec_dir = runner_dir

local filter = arg and arg[1]
local specs = {}
for name in lfs.dir(runner_dir) do
    if name:match("_spec%.lua$") and (not filter or name:find(filter, 1, true)) then
        specs[#specs + 1] = name
    end
end
table.sort(specs)

io.write(string.format("Kamare specs (%d file(s))\n", #specs))
for _, name in ipairs(specs) do
    io.write("== ", name, "\n")
    local chunk, err = loadfile(runner_dir .. "/" .. name)
    if not chunk then
        record(false, name .. ": " .. tostring(err))
    else
        local ok, spec = pcall(chunk, t)
        if not ok then
            record(false, name .. " raised: " .. tostring(spec))
        elseif type(spec) == "function" then
            local sok, serr = pcall(spec, t)
            if not sok then
                record(false, name .. " raised: " .. tostring(serr))
            end
        end
    end
end

remove_tree(tmp_root)

io.write(string.format("\n%d passed, %d failed\n", results.passed, results.failed))
if results.failed > 0 then
    for _, e in ipairs(results.errors) do io.write("  - ", e, "\n") end
    os.exit(1)
end
