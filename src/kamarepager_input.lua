--[[--
翻页器设备接管（内部模块；对外门面见 `kamarepager`）。

链子：翻页器按键 → 蓝牙（KHP / 系统） → 虚拟键盘 evdev 节点 → 这里打开并交给
KOReader 输入系统 → 门面识别动作并翻页。

三件必须做的事，少一件就是「按了没反应」：
  1. 打开节点：KOReader 启动只开固定几个 event 节点（Kindle 走 FBInk 按 mask 扫，
     Kobo 只开 ntx/touch），后插的翻页器没人 open，事件永远到不了 Lua。
  2. 合并 event_map：`Input:handleKeyBoardEv` 对 event_map 里没有的码直接 return。
  3. 钩子只接翻页器自己的 fd：机身按键（如 Kobo Libra Colour 的 193/194）继续走原生路径。

存活判定用 readlink 目标**比对设备路径**，而不是查 `(deleted)`：C 层在 ENODEV 时
会关掉 fd，但 Lua 侧的 `Input.opened_devices[path]` 不会清；被关掉的 fd 号还可能
被复用、指向一个完全无关的文件。拿 `(deleted)` 当判据会误判为「还活着」，于是
`Input:open` 因为陈旧条目静默跳过，翻页器死到重启为止。

所有外部依赖都能通过 `set_deps` 注入，`spec/pager_spec.lua` 靠它脱设备跑。
--]]

local logger = require("logger")
local ffi = require("ffi")

pcall(ffi.cdef, "ssize_t readlink(const char *path, char *buf, size_t bufsiz);")

local PagerInput = {}

----------------------------------------------------------------------------
-- 依赖注入（测试缝）
----------------------------------------------------------------------------

local deps = {}
local android_mode

--- 注入依赖；`nil` 清空。只覆盖传入的键，其余保持默认。
function PagerInput.set_deps(t)
    android_mode = nil
    if t == nil then
        deps = {}
        return true
    end
    for k, v in pairs(t) do deps[k] = v end
    return true
end

local function device()
    return deps.device or require("device")
end

--- Android 上键事件由系统合成：没有 fd，也没有 /dev/input 节点可接管。
function PagerInput.is_android()
    if android_mode ~= nil then return android_mode end
    local dev = device()
    local ok, result = pcall(function() return dev and dev.isAndroid and dev.isAndroid(dev) end)
    android_mode = (ok and result) and true or false
    return android_mode
end

local function input()
    return deps.input or device().input
end

local function timestamp()
    if deps.now then return deps.now() end
    return require("ffi/util").getTimestamp()
end

local function schedule_in(sec, fn)
    if deps.schedule then return deps.schedule(sec, fn) end
    return require("ui/uimanager"):scheduleIn(sec, fn)
end

local function readlink_of(fd)
    if deps.readlink then return deps.readlink(fd) end
    local buf = ffi.new("char[?]", 512)
    local n = ffi.C.readlink("/proc/self/fd/" .. tostring(fd), buf, 511)
    if not n or n <= 0 then return nil end
    return ffi.string(buf, n)
end

local function proc_devices()
    if deps.read_proc then return deps.read_proc() end
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

----------------------------------------------------------------------------
-- 常量
----------------------------------------------------------------------------

-- 机身自带设备，别去动。名字按真机上看到的写：Kindle 的电源键叫
-- bd71828-pwrkey、触摸屏叫 goodix-ts，只匹配 "power"/"touchscreen" 匹配不上。
PagerInput.BLACKLIST = {
    "volume", "power", "pwrkey", "bd71828", "goodix", "cover", "hall",
    "button", "gpio", "touchscreen", "accelerometer", "bma", "wacom",
    "stylus", "pt_mt", "digitizer",
}

-- 至少命中一个才算翻页器（EV_KEY 能力位里查）。
PagerInput.PAGER_KEYS = { 104, 109, 70 }

-- 同一物理设备的「伴生节点」上可能出现的按键：音量、方向、媒体。
-- 蓝牙 HID 设备常把键盘和用户控制拆成两个 event 节点，翻页键只在其中一个上，
-- 另一个（音量那一类）同样要接管，否则那颗键永远到不了 Lua。
PagerInput.COMPANION_KEYS = {
    103, 105, 106, 108,          -- 方向键
    113, 114, 115,               -- 静音 / 音量- / 音量+
    128,                         -- 电话挂断（部分遥控器）
    163, 164, 165, 166, 167, 168, -- 媒体键
    208,                         -- 播放/暂停（部分翻页器）
}

-- 只补空缺，不动机身已有的键；值与 KOReader / ko-pageturner 对齐，
-- 否则按键放行给原生处理时方向会和他们相反。
PagerInput.EVENT_MAP = {
    [70] = "ScrollLock",
    [104] = "LPgBack",  -- PageUp
    [109] = "LPgFwd",   -- PageDown
    [103] = "Up", [108] = "Down", [105] = "Left", [106] = "Right",
    [28] = "Press", [158] = "Back", [102] = "Home",
}

-- Android 的键码是 **Android keycode**，和 Linux evdev 码完全不是一回事；
-- 而且键事件由系统直接送进 KOReader，没有 fd、也没有 /dev/input 节点可接管。
-- 这里只补几个媒体键 → 翻页键，其余保持 KOReader 自己的映射。
PagerInput.ANDROID_EVENT_MAP = {
    [85] = "LPgFwd",   -- MEDIA_PLAY_PAUSE（遥控器中间那颗）
    [86] = "LPgFwd",   -- MEDIA_STOP
    [87] = "LPgFwd",   -- MEDIA_NEXT（右翻页）
    [88] = "LPgBack",  -- MEDIA_PREVIOUS（左翻页）
    [126] = "LPgFwd",  -- MEDIA_PLAY
    [127] = "LPgFwd",  -- MEDIA_PAUSE
}

PagerInput.CLOSE_WINDOW = 60
PagerInput.CLOSE_LIMIT = 3

----------------------------------------------------------------------------
-- 状态
----------------------------------------------------------------------------

PagerInput.opened = {}    -- path -> { path, name, fd, ours }
PagerInput.fd_path = {}   -- fd -> path
PagerInput._closes = {}   -- path -> { ts, ... }（熔断统计）
PagerInput._blocked = {}  -- path -> true（熔断中，暂停重开）
PagerInput.last_error = nil
--- 最近一次从翻页器收到的按键；排查「某颗键没反应」时看它就知道码是多少。
PagerInput.last_key = nil
PagerInput.keys_seen = 0
PagerInput._reported = {}  -- path -> true（「看到但没接管」只记一次，免得刷日志）
PagerInput._signature = nil -- 上一次记日志时的节点清单签名
--- 最近的按键（环形缓冲，最多 64 条）：「保存诊断」时一起写出去。
PagerInput.KEY_LOG_MAX = 64
PagerInput.key_log = {}

local handler        -- 门面的事件处理函数
local notifier       -- connect / disconnect 通知
local sniffer        -- 嗅探模式下的按键回调（诊断）
local hook_orig      -- 装钩子前的 handleKeyBoardEv
local hook_input     -- 装钩子时用的 Input 实例（恢复时必须还给同一个）

----------------------------------------------------------------------------
-- /proc/bus/input/devices 解析
----------------------------------------------------------------------------

--- 一个 64 位字里某一位是否置位。字串是十六进制、可能省略高位 0。
local function word_has_bit(word, bit)
    if #word < 16 then word = string.rep("0", 16 - #word) .. word end
    local nibble = math.floor(bit / 4)
    local ch = word:sub(16 - nibble, 16 - nibble)
    local value = tonumber(ch, 16)
    if not value then return false end
    return math.floor(value / (2 ^ (bit % 4))) % 2 == 1
end

--- `B: KEY=` 那一串（多字、空格分隔、**高位字在前**）里 code 是否置位。
function PagerInput.key_bit_set(bitmap, code)
    if type(bitmap) ~= "string" then return false end
    local words = {}
    for w in bitmap:gmatch("%S+") do words[#words + 1] = w end
    local total = #words
    if total == 0 then return false end
    local index = total - math.floor(code / 64)
    if index < 1 then return false end
    return word_has_bit(words[index], code % 64)
end

--- 这个节点声明了哪些按键（0..767）。诊断用：一次就能看出设备到底能发什么。
PagerInput._codes_cache = {}

function PagerInput.key_codes(bitmap)
    if type(bitmap) ~= "string" then return {} end
    local cached = PagerInput._codes_cache[bitmap]
    if cached then return cached end
    local out = {}
    for code = 0, 767 do
        if PagerInput.key_bit_set(bitmap, code) then out[#out + 1] = code end
    end
    PagerInput._codes_cache[bitmap] = out
    return out
end

--- 解析 /proc/bus/input/devices。返回 { { name, event, keybits } ... }。
function PagerInput.parse(text)
    local out = {}
    if type(text) ~= "string" then return out end
    local current
    local function flush()
        if current and current.name and current.event then out[#out + 1] = current end
        current = nil
    end
    for line in text:gmatch("[^\r\n]+") do
        if line:match("^I:") then
            flush()
            current = {}
        elseif current then
            local name = line:match('^N:%s*Name="(.-)"')
            local handlers = line:match("^H:%s*Handlers=(.*)$")
            local keys = line:match("^B:%s*KEY=(.*)$")
            local uniq = line:match("^U:%s*Uniq=(.*)$")
            local phys = line:match("^P:%s*Phys=(.*)$")
            if name then
                current.name = name
            elseif handlers then
                local ev = handlers:match("(event%d+)")
                current.event = ev and ("/dev/input/" .. ev) or nil
            elseif keys then
                current.keybits = keys
            elseif uniq then
                current.uniq = uniq:gsub("%s+$", "")
            elseif phys then
                current.phys = phys:gsub("%s+$", "")
            end
        end
    end
    flush()
    return out
end

local function blacklisted(name)
    if not name then return true end
    local low = name:lower()
    for __, pattern in ipairs(PagerInput.BLACKLIST) do
        if low:find(pattern, 1, true) then return true end
    end
    return false
end

local function is_pager(dev)
    if not dev or not dev.event or blacklisted(dev.name) then return false end
    for __, code in ipairs(PagerInput.PAGER_KEYS) do
        if PagerInput.key_bit_set(dev.keybits, code) then return true end
    end
    return false
end

--- 同一物理设备的标识：优先 MAC（Uniq），其次 Phys，最后退回名字。
--- 不能按 Sysfs 分组：KHP 之类的虚拟设备全都挂在 /devices/virtual/input 下。
local function group_key(dev)
    if dev.uniq and dev.uniq ~= "" then return "uniq:" .. dev.uniq end
    if dev.phys and dev.phys ~= "" then return "phys:" .. dev.phys end
    return "name:" .. tostring(dev.name)
end

--- 这个节点上有翻页器可能用到的其它按键吗（音量/方向/媒体）。
local function has_companion_key(dev)
    if not dev or not dev.event then return false end
    for __, code in ipairs(PagerInput.COMPANION_KEYS) do
        if PagerInput.key_bit_set(dev.keybits, code) then return true end
    end
    return false
end

----------------------------------------------------------------------------
-- 设备打开 / 释放
----------------------------------------------------------------------------

local function set_error(message)
    PagerInput.last_error = message
end

local function notify(event, dev)
    if not notifier then return end
    pcall(notifier, event, dev and { path = dev.path, name = dev.name })
end

--- fd 还指向这个设备吗？路径比对，不是「没被删就算活着」。
function PagerInput.alive(record)
    if not record or not record.fd then return false end
    return readlink_of(record.fd) == record.path
end

local function record_close(path)
    local ts = timestamp()
    local kept = {}
    for __, t in ipairs(PagerInput._closes[path] or {}) do
        if ts - t < PagerInput.CLOSE_WINDOW then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = ts
    PagerInput._closes[path] = kept
    if #kept >= PagerInput.CLOSE_LIMIT then
        PagerInput._blocked[path] = true
        logger.warn("[kamarepager] flapping, pausing reopen for " .. tostring(path))
    end
end

function PagerInput.is_flapping()
    for __, blocked in pairs(PagerInput._blocked) do
        if blocked then return true end
    end
    return false
end

--- 清熔断（Resume / 手动重扫 / 用户重新打开开关）。
function PagerInput.reset_flapping()
    PagerInput._blocked = {}
    PagerInput._closes = {}
end

local function forget(path, dead)
    local record = PagerInput.opened[path]
    if not record then return end
    PagerInput.opened[path] = nil
    if record.fd then PagerInput.fd_path[record.fd] = nil end
    if dead then
        record_close(path)
        -- 陈旧的登记表会让 Input:open 静默跳过，必须清掉。
        local inp = input()
        if inp and inp.opened_devices and inp.opened_devices[path] then
            inp.opened_devices[path] = nil
        end
    end
    notify("disconnect", record)
    logger.info("[kamarepager] device detached: " .. tostring(path))
end

--- KOReader 键名 → 翻页动作。Android 上阅读页的 `key_events` 在真机上
--- 有时根本收不到 KeyPress（音量键/KOReader 自己的阅读器能翻页，Kamare 里不能），
--- 所以这里直接按键名兜底，不依赖阅读页的按键表。
PagerInput.DEFAULT_ACTIONS = {
    LPgFwd = "next", RPgFwd = "next", Down = "next", Right = "next",
    LPgBack = "prev", RPgBack = "prev", Up = "prev", Left = "prev",
}

--- 这颗码在 KOReader 里叫什么、默认该翻哪一页。
function PagerInput.default_action_for(code)
    local inp = input()
    local name = inp and type(inp.event_map) == "table" and inp.event_map[code] or nil
    if not name then return nil end
    return PagerInput.DEFAULT_ACTIONS[name], name
end

--- 把翻页器键码并进 KOReader 的按键映射：只补空缺，幂等。
function PagerInput.merge_event_map()
    local inp = input()
    local map = inp and inp.event_map
    if type(map) ~= "table" then return false end
    -- Android 的键码语义完全不同，不能把 Linux 那套并进去。
    local source = PagerInput.is_android() and PagerInput.ANDROID_EVENT_MAP or PagerInput.EVENT_MAP
    for code, name in pairs(source) do
        if map[code] == nil then map[code] = name end
    end
    return true
end

local function adopt(dev)
    local inp = input()
    if not inp then return nil end

    local record = PagerInput.opened[dev.path]
    if record then
        if PagerInput.alive(record) then
            return record.ours and "attached" or "borrowed"
        end
        forget(dev.path, true)
    end

    if PagerInput._blocked[dev.path] then return nil end

    -- 别人先开了：借道，不抢 fd、不 close 别人的。
    local registry = inp.opened_devices
    local existing = registry and registry[dev.path]
    if existing then
        PagerInput.opened[dev.path] = {
            path = dev.path, name = dev.name, fd = existing, ours = false,
        }
        PagerInput.fd_path[existing] = dev.path
        PagerInput._reported[dev.path] = nil
        notify("connect", dev)
        logger.info("[kamarepager] borrowed " .. tostring(dev.path) .. " (" .. tostring(dev.name) .. ")")
        return "borrowed"
    end

    -- C 层打开失败是 luaL_error，不包会打断整个 attach。
    local ok, fd = pcall(inp.open, inp, dev.path, dev.name)
    if not ok then
        set_error(tostring(fd))
        logger.warn("[kamarepager] open failed " .. tostring(dev.path) .. ": " .. tostring(fd))
        return nil
    end
    if type(fd) ~= "number" or fd < 0 then
        set_error("open returned no fd")
        return nil
    end

    PagerInput.opened[dev.path] = {
        path = dev.path, name = dev.name, fd = fd, ours = true,
    }
    PagerInput.fd_path[fd] = dev.path
    PagerInput._reported[dev.path] = nil
    notify("connect", dev)
    logger.info(string.format("[kamarepager] attached %s (%s) fd=%d",
        tostring(dev.path), tostring(dev.name), fd))
    return "attached"
end

--- 从 /proc 文本里挑出候选翻页器（已过滤黑名单与能力位）。
--- 一台翻页器可能占多个 event 节点（键盘 + 用户控制），只要同组里有一个节点
--- 带翻页键码，整组里带按键的节点都要接管 —— 否则「只翻页键在那半边」的
--- 设备会出现「下键好用、上键没反应」。
function PagerInput.candidates(text)
    local groups = {}
    for __, dev in ipairs(PagerInput.parse(text)) do
        if dev.event then
            local key = group_key(dev)
            local group = groups[key]
            if not group then
                group = { key = key, members = {} }
                groups[key] = group
            end
            group.members[#group.members + 1] = dev
        end
    end

    local out = {}
    for __, group in pairs(groups) do
        local qualifies = false
        for __, dev in ipairs(group.members) do
            if is_pager(dev) then qualifies = true break end
        end
        if qualifies then
            for __, dev in ipairs(group.members) do
                -- 同一物理设备的兄弟节点全部接管：翻页键可能在另一个集合上，
                -- 而那个集合声明哪些码我们事先并不知道。
                if not blacklisted(dev.name) then
                    out[#out + 1] = { path = dev.event, name = dev.name, group = group.key }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

--- 扫一遍并接管还没接上的设备。返回 attached, borrowed。
function PagerInput.attach()
    PagerInput.merge_event_map()
    local attached, borrowed = 0, 0
    local text = proc_devices()
    local list = PagerInput.candidates(text)
    for __, dev in ipairs(list) do
        local state = adopt(dev)
        if state == "attached" then
            attached = attached + 1
        elseif state == "borrowed" then
            borrowed = borrowed + 1
        end
    end
    if #list > 0 or PagerInput.is_android() then
        PagerInput.install_hook()
        if PagerInput.is_android() then PagerInput.install_backend_hook() end
    end
    PagerInput.report_skips(text, list)
    PagerInput.dump_inventory()
    return attached, borrowed
end

--- 「像遥控器/键盘、但没被接管」的节点记一行日志：真机上 grep kamarepager
--- 就能看出是漏在分组外、还是根本没这个节点。
function PagerInput.report_skips(text, adopted)
    local adopted_paths = {}
    for __, dev in ipairs(adopted or {}) do adopted_paths[dev.path] = true end
    for __, dev in ipairs(PagerInput.parse(text)) do
        if dev.event and not adopted_paths[dev.event]
            and not blacklisted(dev.name)
            and (has_companion_key(dev) or is_pager(dev)) then
            if not PagerInput._reported[dev.event] then
                PagerInput._reported[dev.event] = true
                logger.info(string.format("[kamarepager] seen but not adopted: %s (%s)",
                    tostring(dev.name), tostring(dev.event)))
            end
        end
    end
end

--- 清死 fd（设备被删掉但我们还记着）。
function PagerInput.prune()
    local removed = 0
    for path, record in pairs(PagerInput.opened) do
        if not PagerInput.alive(record) then
            forget(path, true)
            removed = removed + 1
        end
    end
    return removed
end

--- prune + attach。返回本次新接管的数量。
function PagerInput.rescan()
    PagerInput.prune()
    local attached, borrowed = PagerInput.attach()
    return attached, borrowed
end

--- 释放我们自己的 fd（`borrowed` 的不碰），卸钩子。
function PagerInput.detach()
    local inp = input()
    for path, record in pairs(PagerInput.opened) do
        if record.ours and inp then
            pcall(inp.close, inp, path)
        end
        if record.fd then PagerInput.fd_path[record.fd] = nil end
        PagerInput.opened[path] = nil
    end
    PagerInput.uninstall_hook()
    PagerInput.stop_loop()
end

--- 状态快照（供门面 status()）。
function PagerInput.devices()
    local list = {}
    for path, record in pairs(PagerInput.opened) do
        list[#list + 1] = {
            path = path, name = record.name, fd = record.fd, ours = record.ours,
        }
    end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

function PagerInput.path_for_fd(fd)
    return PagerInput.fd_path[fd]
end

--- 钩子**现在**还在不在。只看 hook_orig 会撒谎：别的东西（Moon 自带的物理翻页键、
--- ko-pageturner 等）可能事后把 handleKeyBoardEv 换掉，我们就再也收不到键了。
--- 注意：Android 的兜底层不再依赖这个判断（每颗键只喂一次），它只用于诊断。
function PagerInput.handler_installed()
    return type(handler) == "function"
end

function PagerInput.hook_installed()
    local inp = input()
    return hook_orig ~= nil and inp ~= nil and inp.handleKeyBoardEv == PagerInput.dispatch
end

--- 这个平台的输入后端支持 `Input:open` 吗？（SDL 桌面模拟器就不支持）
function PagerInput.can_open()
    local inp = input()
    return type(inp and inp.open) == "function"
end

--- 当前 `/proc` 里的节点清单 + 每个节点的判定结果（诊断页用）。
function PagerInput.snapshot()
    local list = {}
    for __, dev in ipairs(PagerInput.parse(proc_devices())) do
        if dev.event then
            local record = PagerInput.opened[dev.event]
            list[#list + 1] = {
                name = dev.name,
                path = dev.event,
                keybits = dev.keybits,
                codes = PagerInput.key_codes(dev.keybits),
                blacklisted = blacklisted(dev.name),
                pager = is_pager(dev),
                companion = has_companion_key(dev),
                adopted = record ~= nil,
                ours = record and record.ours or nil,
            }
        end
    end
    return list
end

--- 节点集合一变就记一次全量清单：后插的翻页器也能在 crash.log 里看到。
function PagerInput.dump_inventory()
    local list = PagerInput.snapshot()
    local parts, rows = {}, {}
    for __, dev in ipairs(list) do
        local tags = {}
        if dev.blacklisted then tags[#tags + 1] = "blacklist" end
        if dev.pager then tags[#tags + 1] = "pager" end
        if dev.companion then tags[#tags + 1] = "companion" end
        if dev.adopted then tags[#tags + 1] = dev.ours and "adopted" or "borrowed" end
        if #tags == 0 then tags[#tags + 1] = "ignored" end
        local tags_text = table.concat(tags, ",")
        local codes_text = table.concat(dev.codes or {}, ",")
        rows[#rows + 1] = string.format("[kamarepager] node %s %s [%s] keys=%s",
            dev.path, tostring(dev.name), tags_text, codes_text)
        parts[#parts + 1] = dev.path .. "=" .. tostring(dev.name)
            .. "[" .. tags_text .. "]" .. codes_text
    end
    local signature = table.concat(parts, "|")
    if signature == PagerInput._signature then return end
    PagerInput._signature = signature
    logger.info(string.format("[kamarepager] %d input node(s), open=%s hook=%s",
        #list, tostring(PagerInput.can_open()), tostring(PagerInput.hook_installed())))
    for __, row in ipairs(rows) do logger.info(row) end
end

----------------------------------------------------------------------------
-- 按键钩子
----------------------------------------------------------------------------

function PagerInput.set_handler(fn) handler = fn end
function PagerInput.set_notifier(fn) notifier = fn end
function PagerInput.set_sniffer(fn) sniffer = fn end

----------------------------------------------------------------------------
-- 按键嗅探（诊断用）
--
-- 只接管「翻页器节点」时，如果某颗键其实来自另一个节点，我们永远看不到它。
-- 嗅探会临时打开**所有** event 节点（已经开着的借用），把每个按键的
-- fd / code / value 都记下来，N 秒后自动释放。
----------------------------------------------------------------------------

PagerInput.sniffing = false
PagerInput.sniff_opened = {}
PagerInput.sniff_names = {}   -- fd -> name（诊断显示用）

function PagerInput.sniff_active()
    return PagerInput.sniffing == true
end

function PagerInput.start_sniff()
    if PagerInput.sniffing then return true end
    -- Android 上没有 evdev 节点可开，键事件本来就直接进 KOReader 了。
    if PagerInput.is_android() then return false, "android" end
    local inp = input()
    if not inp or type(inp.open) ~= "function" then return false, "no_open" end

    PagerInput.sniff_opened = {}
    for __, dev in ipairs(PagerInput.parse(proc_devices())) do
        if dev.event then
            local existing = inp.opened_devices and inp.opened_devices[dev.event]
            if existing then
                local added = PagerInput.fd_path[existing] == nil
                if added then PagerInput.fd_path[existing] = dev.event end
                PagerInput.sniff_names[existing] = dev.name
                PagerInput.sniff_opened[#PagerInput.sniff_opened + 1] = {
                    path = dev.event, fd = existing, name = dev.name,
                    ours = false, clear_path = added,
                }
            else
                local ok, fd = pcall(inp.open, inp, dev.event, dev.name)
                if ok and type(fd) == "number" and fd >= 0 then
                    PagerInput.fd_path[fd] = dev.event
                    PagerInput.sniff_names[fd] = dev.name
                    PagerInput.sniff_opened[#PagerInput.sniff_opened + 1] = {
                        path = dev.event, fd = fd, name = dev.name,
                        ours = true, clear_path = true,
                    }
                else
                    logger.warn("[kamarepager] sniff: cannot open "
                        .. tostring(dev.event) .. ": " .. tostring(fd))
                end
            end
        end
    end

    PagerInput.sniffing = true
    PagerInput.install_hook()
    logger.info(string.format("[kamarepager] sniff started on %d node(s)",
        #PagerInput.sniff_opened))
    return true
end

function PagerInput.stop_sniff()
    if not PagerInput.sniffing then return true end
    PagerInput.sniffing = false
    local inp = input()
    for __, rec in ipairs(PagerInput.sniff_opened) do
        if rec.ours and inp then pcall(inp.close, inp, rec.path) end
        if rec.clear_path then PagerInput.fd_path[rec.fd] = nil end
    end
    PagerInput.sniff_opened = {}
    PagerInput.sniff_names = {}
    logger.info("[kamarepager] sniff stopped")
    return true
end

--- 记录 + 交给门面。返回 true 表示门面吃掉了这颗键。
--- `dispatch` 与 Android 媒体键劫持（没有 fd 的合成事件）共用这一条路径，
--- 这样诊断页的「最近按键」对两种来源都有效。
--- 记一笔最近的按键（诊断页/日志共用），不做任何动作。
local function record_key(ev)
    local path = ev.fd and PagerInput.fd_path[ev.fd]
    local track = path ~= nil or PagerInput.sniffing or PagerInput.is_android()
    if not track then return nil end
    local record = path and PagerInput.opened[path]
    local entry = {
        code = ev.code, value = ev.value, fd = ev.fd, path = path,
        name = (record and record.name) or PagerInput.sniff_names[ev.fd]
            or (PagerInput.is_android() and (ev.media and "Android/media" or "Android")),
        ts = timestamp(),
    }
    PagerInput.last_key = entry
    local log = PagerInput.key_log
    log[#log + 1] = entry
    if #log > PagerInput.KEY_LOG_MAX then table.remove(log, 1) end
    if ev.value == 1 then
        PagerInput.keys_seen = PagerInput.keys_seen + 1
        -- 记下来自翻页器节点的每一个键码（包括没绑定的），
        -- 真机上 grep kamarepager 就能看出「上键到底发的是什么」。
        logger.info(string.format("[kamarepager] %skey code=%s from %s (%s)",
            PagerInput.sniffing and "sniff " or "",
            tostring(ev.code), tostring(path), tostring(entry.name)))
    end
    if PagerInput.sniffing and sniffer then pcall(sniffer, entry) end
    -- Android 没有 fd：让诊断页/订阅者也能收到按键（按一下刷新一下）。
    if not path and ev.value == 1 and sniffer and not PagerInput.sniffing then
        pcall(sniffer, entry)
    end
    return entry
end

function PagerInput.feed(ev)
    if type(ev) ~= "table" then return false end
    record_key(ev)
    if handler then
        local ok, consumed = pcall(handler, ev)
        if ok and consumed then return true end
    end
    return false
end

--- 只把「来自翻页器 fd」的事件交给 handler；其余原样放行。
--- Android 上兜底层（backend_wait）可能已经喂过这颗事件，标记一下就跳过，
--- 保证一颗键只处理一次。
function PagerInput.dispatch(self, ev)
    if type(ev) == "table" and ev[PagerInput.FED_MARK] then
        return hook_orig(self, ev)
    end
    PagerInput.fed_hook = (PagerInput.fed_hook or 0) + 1
    if PagerInput.feed(ev) then return nil end
    local out = hook_orig(self, ev)
    -- 没绑定的键最后被 KOReader 变成了什么事件：KeyPress / nil（没人认）。
    -- 诊断页显示它，就能区分「键到了但 KOReader 不认」和「认了但没翻页」。
    if type(ev) == "table" and ev.value == 1 then
        PagerInput.last_passthrough = out and tostring(out.handler) or "nil"
    end
    return out
end

--- 装钩子。幂等，而且会**自愈**：如果 handleKeyBoardEv 已经不是我们的了
--- （被别的插件换掉，或者我们在一个后来被替换掉的 Input 实例上装过），
--- 就重新装一次，并把当前那个处理函数串在我们后面，别把别人的功能弄丢。
function PagerInput.install_hook()
    local inp = input()
    if not inp then return false end
    if hook_orig and inp.handleKeyBoardEv == PagerInput.dispatch then return true end
    -- 启动早期 inhibitInput 会把 handleKeyBoardEv 换成只管电源键的函数，
    -- 真正的实现留在 _key_ev_handler 上。
    local orig = inp._key_ev_handler or inp.handleKeyBoardEv
    if type(orig) ~= "function" then return false end
    if orig == PagerInput.dispatch then
        -- 只有 handleKeyBoardEv 被人改了：直接装回去，不重新串。
        inp.handleKeyBoardEv = PagerInput.dispatch
        return true
    end
    if hook_orig and orig ~= hook_orig then
        logger.info("[kamarepager] input hook was replaced, reinstalling")
    end
    hook_orig = orig
    hook_input = inp
    inp.handleKeyBoardEv = PagerInput.dispatch
    -- inhibitInput/restore 会用 _key_ev_handler 覆盖 handleKeyBoardEv，一起指过来才不会被冲掉。
    if inp._key_ev_handler then inp._key_ev_handler = PagerInput.dispatch end
    return true
end

----------------------------------------------------------------------------
-- Android 兜底：在输入后端出口再挂一层
----------------------------------------------------------------------------
--
-- 真机上出现过「诊断页里四颗键能上下左右滚弹框，但插件一条也没记到」的情况：
-- 说明 `Input:handleKeyBoardEv` 已经被别的东西换掉了，我们的钩子不在链子上。
-- 光靠自愈要等下一次 attach；这里在 `Device.input.input.waitForEvent`
-- （Android 的 `ffi/input_android`）的返回处再兜一层：
--
--   * 只有我们的钩子**不在**链上时才启用（否则一次按键处理两遍）；
--   * KOReader 自己 event_map 里认得的码只记账、不分发（避免一次翻两页）；
--   * 其余码照常走 feed()，绑定/捕获不受影响。

local backend_mod, backend_orig

function PagerInput.install_backend_hook()
    local inp = input()
    local backend = inp and inp.input
    if type(backend) ~= "table" or type(backend.waitForEvent) ~= "function" then
        return false
    end
    if backend_mod == backend and backend.waitForEvent == PagerInput.backend_wait then
        return true
    end
    backend_mod = backend
    backend_orig = backend.waitForEvent
    backend.waitForEvent = PagerInput.backend_wait
    return true
end

local function feed_foreign(ev)
    -- KOReader 认得这些码也没关系：默认动作只在阅读页最上层时执行，
    -- 而真机上 Kamare 阅读页的 key_events 收不到 KeyPress（原生阅读器能翻、
    -- 这里不能），所以必须由我们自己兜。
    return PagerInput.feed(ev)
end

function PagerInput.uninstall_backend_hook()
    if not backend_mod then return false end
    if backend_mod.waitForEvent == PagerInput.backend_wait then
        backend_mod.waitForEvent = backend_orig
    end
    backend_mod, backend_orig = nil, nil
    return true
end

function PagerInput.backend_hooked()
    return backend_mod ~= nil and backend_mod.waitForEvent == PagerInput.backend_wait
end

PagerInput.FED_MARK = "__kamare_fed"

function PagerInput.backend_wait(sec, usec)
    local ok, evs = backend_orig(sec, usec)
    if ok and type(evs) == "table" then
        for i = 1, #evs do
            local ev = evs[i]
            if type(ev) == "table" and ev.type == 1 and not ev[PagerInput.FED_MARK] then
                ev[PagerInput.FED_MARK] = true
                PagerInput.fed_backend = (PagerInput.fed_backend or 0) + 1
                local ok2, err = pcall(feed_foreign, ev)
                if not ok2 then
                    logger.warn("[kamarepager] backend feed failed: " .. tostring(err))
                end
            end
        end
    end
    return ok, evs
end

function PagerInput.uninstall_hook()
    if not hook_orig then return end
    local inp = hook_input or input()
    if inp then
        inp.handleKeyBoardEv = hook_orig
        if inp._key_ev_handler then inp._key_ev_handler = hook_orig end
    end
    hook_orig = nil
    hook_input = nil
end

----------------------------------------------------------------------------
-- Android：把 KOReader 丢给系统的媒体键捞回来
----------------------------------------------------------------------------
--
-- `base/ffi/input_android.lua` 的 keyEventHandler 对媒体键直接 `return 0`，
-- 事件交还给系统，Lua 侧一个字都看不到。蓝牙翻页器/遥控器的四向键基本都发
-- 这一类码（上一曲/下一曲/快进/快退），所以真机上只剩中间那颗（Enter）
-- 和音量键能用。
--
-- 这里不改任何文件：把 `android.lib` 换成一个代理表，只在
-- `AInputQueue_finishEvent` 上挂一层。KOReader 已经决定**不处理**
-- （handled == 0）的键事件，由我们按 `want()` 决定要不要接管（接管就强制
-- handled = 1）；其余按键、触摸完全走原路径，出问题最坏也只是回到「丢给系统」。
-- `want()` 只在这几种情况下点头：正在等用户按键（捕获），或者这颗码已经绑过、
-- 或者是语义明确的「上一首/下一首」（87/88，遥控器的左右键常发这个）；后两种
-- 还要求 Kamare 阅读页就在最上层。所以平时不会抢系统音量和音乐控制。

-- AKEYCODE_MEDIA_*（85-91、126-130）。这些是最常见的一类，但**不是全部**：
-- KOReader 的 `keyEventHandler` 还会 `return 0` 掉 HEADSETHOOK(79)、
-- VOLUME_MUTE(164) 以及被「忽略音量键」挡下的 24/25。遥控器上那两颗
-- 「左右翻页」很可能就落在这些码上 —— 只认 MEDIA_CODES 会让它们永远绑不上。
-- 实际判定见 `grab_event`（不再按码过滤）；这张表保留给文档/诊断引用。
PagerInput.MEDIA_CODES = {
    [85] = true,  -- MEDIA_PLAY_PAUSE
    [86] = true,  -- MEDIA_STOP
    [87] = true,  -- MEDIA_NEXT
    [88] = true,  -- MEDIA_PREVIOUS
    [89] = true,  -- MEDIA_REWIND
    [90] = true,  -- MEDIA_FAST_FORWARD
    [91] = true,  -- MUTE
    [126] = true, -- MEDIA_PLAY
    [127] = true, -- MEDIA_PAUSE
    [128] = true, -- MEDIA_CLOSE
    [129] = true, -- MEDIA_EJECT
    [130] = true, -- MEDIA_RECORD
}

-- 唯一不碰的键：AKEYCODE_POWER(26)。系统本来就不把它交给第三方应用，
-- 硬吃可能在部分设备上影响关机/锁屏。
PagerInput.NEVER_GRAB = {
    [26] = true, -- AKEYCODE_POWER
}

-- 系统音量键：只有用户**显式绑过**才从系统手里拿（`android_wants` 只在
-- `action_by_code` 里有它时才收）。否则「忽略音量键」打开时我们会把它当成
-- 翻页键，等于悄悄覆盖用户自己的设置。这张表给文档/诊断引用。
PagerInput.VOLUME_CODES = {
    [24] = true,  -- VOLUME_UP
    [25] = true,  -- VOLUME_DOWN
    [164] = true, -- VOLUME_MUTE
}

-- 不用绑定就该生效的 Android 码：只有语义明确是「上一首/下一首」的两颗
-- （MEDIA_PREVIOUS / MEDIA_NEXT）—— 遥控器的左右翻页键常常就是它们。
-- 播放/暂停、停止、静音这些能当中间键用，但它们同时也是音乐控制：
-- 不自动抢，用户真要拿它翻页时自己绑。
PagerInput.AUTO_GRAB_CODES = {
    [87] = true, -- MEDIA_NEXT
    [88] = true, -- MEDIA_PREVIOUS
}

local grab

-- AINPUT_EVENT_TYPE_*（NDK 常量，不依赖 C 头文件）
local AINPUT_EVENT_TYPE_KEY = 1
local AINPUT_EVENT_TYPE_MOTION = 2
local GRAB_RECENT_MAX = 16

local function grab_record(g, etype, code, action, handled)
    local seen = g.seen
    seen[etype] = (seen[etype] or 0) + 1
    local raw = { type = etype, code = code, action = action, handled = handled }
    g.last_raw = raw
    g.recent[#g.recent + 1] = raw
    if #g.recent > GRAB_RECENT_MAX then table.remove(g.recent, 1) end
end

local function grab_drain(g)
    g.scheduled = false
    local queue = g.queue
    g.queue = {}
    for i = 1, #queue do
        local ev = queue[i]
        local ok, err = pcall(g.dispatch, ev.code, ev.value)
        if not ok then
            logger.warn("[kamarepager] android media dispatch failed: " .. tostring(err))
        end
    end
end

local function grab_schedule(g)
    if g.scheduled then return end
    g.scheduled = true
    -- 不在输入回调里直接翻页：交给 UI 循环下一拍，和正常按键的时序一致。
    local ok = pcall(schedule_in, 0.01, function() grab_drain(g) end)
    if not ok then
        g.scheduled = false
        grab_drain(g)
    end
end

--- 读一个 AInputEvent：键事件返回 code, value，否则 nil。
---
--- 这里**不再按码过滤**。桥把事件还给系统时（`handled == 0`）Lua 侧永远看不到，
--- 媒体键、HEADSETHOOK、静音键、被忽略的音量键都是这一类；翻页器发什么码事先
--- 并不知道，只放 MEDIA_CODES 会让「左右翻页」这种偏门码永远绑不上。
--- 要不要真的吃掉交给 `want()`（捕获中 / 已绑定且阅读页在最上层）决定。
---
--- 另外：KOReader 自己处理掉的键（方向键、翻页键……，`handled ~= 0`）也照样记进
--- `recent`，诊断页才能回答「这颗键到底是不是键事件」。绑定期间再补喂一次，
--- 这样即使 Lua 钩子没装上（inhibitInput 抢走 handleKeyBoardEv 等），也能绑。
local function grab_event(g, event, handled)
    local lib = g.lib
    local etype = lib.AInputEvent_getType(event)
    if etype ~= AINPUT_EVENT_TYPE_KEY then
        grab_record(g, etype, nil, nil, handled)
        return false
    end
    local code = lib.AKeyEvent_getKeyCode(event)
    local action = lib.AKeyEvent_getAction(event)
    grab_record(g, etype, code, action, handled)
    if PagerInput.NEVER_GRAB[code] then return false end
    local value
    if action == 0 then value = 1          -- AKEY_EVENT_ACTION_DOWN
    elseif action == 1 then value = 0      -- AKEY_EVENT_ACTION_UP
    else return false end                  -- MULTIPLE

    if handled ~= 0 then
        -- KOReader 已经处理了这颗键：平时绝不重复喂（会翻两次），
        -- 只有「正在绑定」时补喂一次，让绑定不依赖 Lua 钩子是否还在链上。
        if value == 1 and g.observe and g.observe(code, value) then
            g.queue[#g.queue + 1] = { code = code, value = value }
            grab_schedule(g)
        end
        return false
    end

    if value == 1 then
        if not g.want(code, value) then return false end
        g.held[code] = (g.held[code] or 0) + 1
    else
        -- 按下被我们吃了，松开也得吃，否则系统会收到半颗键。
        if (g.held[code] or 0) == 0 then return false end
        g.held[code] = g.held[code] - 1
    end
    g.grabbed = g.grabbed + 1
    g.last = code
    g.queue[#g.queue + 1] = { code = code, value = value }
    grab_schedule(g)
    return true
end

function PagerInput.android_grab_installed()
    return grab ~= nil and grab.error == nil
end

function PagerInput.android_grab_count()
    return grab and grab.grabbed or 0
end

--- 最近一颗被我们从系统手里捞回来的键码（诊断用）。
function PagerInput.android_grab_last()
    return grab and grab.last or nil
end

function PagerInput.android_grab_error()
    return grab and grab.error or nil
end

--- 最近一次从 `AInputQueue_finishEvent` 看到的原始事件（诊断用）。
function PagerInput.android_grab_raw()
    if not grab then return nil end
    return {
        key = grab.seen[AINPUT_EVENT_TYPE_KEY] or 0,
        motion = grab.seen[AINPUT_EVENT_TYPE_MOTION] or 0,
        other = (grab.seen[0] or 0) + (grab.seen[3] or 0),
        last = grab.last_raw,
    }
end

--- 安装 Android 媒体键劫持。`want(code, value)` 同步决定要不要这颗键，
--- `dispatch(code, value)` 延后执行（会走 feed()）。
--- `observe(code, value)` 只在「KOReader 已处理的键」上调用，返回真表示
--- 现在正在绑定、需要补喂一次（不改 handled，不抢系统）。
function PagerInput.install_android_grab(want, dispatch, observe)
    if grab then return grab.error == nil, grab.error end
    if not PagerInput.is_android() then return false, "not_android" end
    if type(want) ~= "function" or type(dispatch) ~= "function" then
        return false, "bad_callback"
    end
    local android = deps.android
    if not android then
        local ok, mod = pcall(require, "android")
        if not ok or type(mod) ~= "table" then return false, "no_android_module" end
        android = mod
    end
    local ok_lib, lib = pcall(function() return android.lib end)
    if not ok_lib or lib == nil then return false, "no_android_lib" end
    local ok_orig, orig = pcall(function() return lib.AInputQueue_finishEvent end)
    if not ok_orig or orig == nil then return false, "no_finish_event" end

    grab = {
        android = android, lib = lib, orig = orig,
        want = want, dispatch = dispatch, observe = observe,
        held = {}, queue = {}, grabbed = 0, scheduled = false,
        seen = {}, recent = {}, last_raw = nil,
    }

    local proxy = setmetatable({}, {
        __index = function(_, key) return lib[key] end,
    })
    proxy.AInputQueue_finishEvent = function(queue, event, handled)
        if grab and not grab.error then
            local ok, took = pcall(grab_event, grab, event, handled)
            if ok then
                if took then handled = 1 end
            else
                grab.error = tostring(took)
                logger.warn("[kamarepager] android media grab failed: " .. tostring(took))
            end
        end
        return orig(queue, event, handled)
    end
    android.lib = proxy
    logger.info("[kamarepager] android media grab installed")
    return true
end

--- 卸载（恢复原来的 android.lib）。只在测试/排查时用。
function PagerInput.uninstall_android_grab()
    if not grab then return false end
    pcall(function() grab.android.lib = grab.lib end)
    grab = nil
    return true
end

----------------------------------------------------------------------------
-- 阅读页内的轻扫
----------------------------------------------------------------------------

PagerInput.SCAN_INTERVAL = 10
PagerInput.SCAN_BACKOFF = 60
PagerInput.SCAN_MISS_LIMIT = 6

local looping = false
local misses = 0

--- 只在 Kamare 阅读页存活期间跑：定时轻扫 + prune，不做全局轮询。
function PagerInput.start_loop()
    if looping then return end
    looping = true
    local function tick()
        local delay = PagerInput.SCAN_INTERVAL
        if misses >= PagerInput.SCAN_MISS_LIMIT then delay = PagerInput.SCAN_BACKOFF end
        schedule_in(delay, function()
            if not looping then return end
            local attached, borrowed = PagerInput.rescan()
            if attached + borrowed > 0 then
                misses = 0
            else
                misses = misses + 1
            end
            tick()
        end)
    end
    tick()
end

function PagerInput.stop_loop()
    looping = false
    misses = 0
end

function PagerInput.loop_active()
    return looping
end

return PagerInput
