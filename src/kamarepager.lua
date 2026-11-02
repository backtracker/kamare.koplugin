--[[--
Public pager facade for other plugins (Moon is the only intended consumer).

Contract (API_VERSION = 1):
  pager.api_version          -> 1
  pager.capabilities         -> { status, events, bindings, bind }
  pager.status()             -> { state, devices, last_error, last_key }
                               -- state: attached | borrowed | flapping | none | disabled
  pager.on(event, callback)  -> handle   -- "key" | "connect" | "disconnect"
  pager.off(handle)          -> true | nil, code, message
  pager.bindings()           -> { next = {109}, prev = {104} }
  pager.add_binding(action, code)     -> true | nil, "duplicate"|"too_many"|"unknown_action"
  pager.remove_binding(action, code)  -> true | nil, "not_found"|"unknown_action"
  pager.reset_bindings()              -> true
  pager.begin_capture(action, cb, seconds) -> true   -- cb(action, code, ok, err)
  pager.cancel_capture()              -> true

Bindings are **lists of raw key codes** (evdev codes on Linux, Android keycodes
on Android) with a per-action cap of 8. They are stored in
G_reader_settings["kamarepager"] and edited from Kamare's own UI
(`show_bindings()`); Moon only ever reads them.

`key` events carry every raw event that came from the *pager's own* file
descriptor (or, on Android, from the system -- there is no fd), bound or not:

  { action = "next"|"prev"|nil, code, value, path, fd }

A callback may `return true` to consume the event; subscribers are consulted
newest-first (the later registrant is the more recently opened window). If
nobody consumes it, the default action runs -- and the default action only
exists inside a Kamare reading page *and* only while that page is the topmost
window: everywhere else the key is passed straight through to KOReader/Moon,
so a binding never steals keys from other UIs.

What is deliberately *not* here:
  - attach / detach / rescan: takeover is permanent for the process lifetime
    (see spec 01); whether the pager is enabled is the user's call, not a
    caller's.
  - `set_context` / `fake_feed` are test seams and never appear in
    `capabilities`.

Failure codes are frozen: not_attached, no_device, unknown_action, code_taken,
flapping. Callers may match on them.

Capability probing: `pcall(require, "kamarepager")` + api_version +
capabilities. A missing module or a different major version means "no pager
support", silently -- never raise at the caller.

Coexistence with pageturner.koplugin (both may be installed): we only swallow
keys we bind, never rewrite Device.hasKeys/hasKeyboard/canKeyRepeat, and we
implement `onGotoViewRel` in the viewer so a pager that another plugin has
taken over still turns Kamare's pages. See spec 02.
--]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local PagerInput = require("kamarepager_input")

--- device 懒加载：spec 环境里没有真实 device，模块加载期不能硬 require。
local function is_android()
    local ok, dev = pcall(require, "device")
    if not ok or not dev or type(dev.isAndroid) ~= "function" then return false end
    local ok2, result = pcall(function() return dev.isAndroid(dev) end)
    return ok2 and result or false
end

local Pager = {}

Pager.api_version = 1
Pager.capabilities = {
    status = true,
    events = true,
    bindings = true,
    bind = true,      -- 绑定可写（Kamare 自己的「按键设置」页在用）
}

local SETTINGS_KEY = "kamarepager"
-- 出厂默认：只认页面前/后翻这两颗标准键。其余一律由用户在「按键设置」里自己指认，
-- 不再猜（猜错一次的代价是「用户删了它还翻页」，比多绑几颗键糟得多）。
local DEFAULT_BINDINGS = { next = { 109 }, prev = { 104 } }
-- 一个动作最多绑几颗键：防手滑，也保证诊断页显示得下。
local MAX_BINDINGS = 8
local GUARD = 0.25

local function copy_list(list)
    local out = {}
    for i = 1, #(list or {}) do out[i] = list[i] end
    return out
end

local function default_bindings()
    return {
        next = copy_list(DEFAULT_BINDINGS.next),
        prev = copy_list(DEFAULT_BINDINGS.prev),
    }
end

--- 当前生效的「键码 → 动作」表。同一个码出现在两边时以 next 为准（add_binding 会先移走）。
local function build_action_map(bindings)
    local map = {}
    if not bindings then return map end
    for __, code in ipairs(bindings.next or {}) do map[code] = "next" end
    for __, code in ipairs(bindings.prev or {}) do map[code] = "prev" end
    return map
end

local state = {
    enabled = true,
    bindings = default_bindings(),
    capture = nil,      -- { action, until_ts, callback }：等待用户按下要绑定的键
    action_by_code = build_action_map(default_bindings()),
    subscribers = {},   -- { { event, callback, seq, dead } }
    seq = 0,
    guard_until = {},   -- fd -> timestamp
    swallowing = {},    -- "fd:code" -> true（按下被吃掉后，松开/重复也一起吃掉）
    started = false,
}

local deps = {}

--- 测试缝：只覆盖传入的键。
function Pager.set_deps(t)
    if t == nil then
        deps = {}
        return true
    end
    for k, v in pairs(t) do deps[k] = v end
    return true
end

--- 把回调裹进 pcall：UI 回调里抛错会直接崩 KOReader（真机上的表现就是崩溃对话框）。
local function guarded(label, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            logger.err("[kamarepager] " .. label .. " failed: " .. tostring(err)
                .. "\n" .. debug.traceback("", 2))
        end
    end
end

local function now()
    if deps.now then return deps.now() end
    return require("ffi/util").getTimestamp()
end

local function read_settings()
    if not G_reader_settings then return {} end
    local saved = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(saved) ~= "table" then return {} end
    return saved
end

local function write_settings(values)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(SETTINGS_KEY, values)
    pcall(function() G_reader_settings:flush() end)
end

--- 当前阅读页实例；模块级懒加载，避免和 viewer 互相 require。
local function active_viewer()
    if deps.viewer then return deps.viewer() end
    local ok, module = pcall(require, "kamareimageviewer")
    if not ok then return nil end
    return module and module.active_instance
end

----------------------------------------------------------------------------
-- 事件总线
----------------------------------------------------------------------------

local VALID_EVENTS = { key = true, connect = true, disconnect = true }

local function emit(event, payload)
    local subs = state.subscribers
    for i = #subs, 1, -1 do
        local sub = subs[i]
        if not sub.dead and sub.event == event then
            local ok, consumed = pcall(sub.callback, payload)
            if not ok then
                logger.warn("[kamarepager] subscriber failed: " .. tostring(consumed))
            elseif consumed then
                return true
            end
        end
    end
    return false
end

--- 订阅翻页器事件。返回一个句柄，交给 `off()` 取消。
function Pager.on(event, callback)
    if not VALID_EVENTS[event] then
        return nil, "unknown_action", "unknown event: " .. tostring(event)
    end
    if type(callback) ~= "function" then
        return nil, "unknown_action", "callback must be a function"
    end
    state.seq = state.seq + 1
    local handle = { seq = state.seq, event = event, callback = callback, dead = false }
    state.subscribers[#state.subscribers + 1] = handle
    return handle
end

function Pager.off(handle)
    if type(handle) ~= "table" then
        return nil, "unknown_action", "off() needs the handle returned by on()"
    end
    handle.dead = true
    return true
end

--- 还有多少个「键」订阅者活着。诊断页用它抓「对话框关了但订阅没退」。
function Pager.subscriber_count()
    local n = 0
    for __, sub in ipairs(state.subscribers) do
        if not sub.dead then n = n + 1 end
    end
    return n
end

--- 测试缝：清空订阅、节流与启动状态。不进 capabilities。
function Pager._reset()
    state.subscribers = {}
    state.guard_until = {}
    state.swallowing = {}
    state.capture = nil
    state.seq = 0
    state.started = false
    state.last_result = nil
    state.gate_override_until = nil
    state.last_keypress = nil
    pcall(PagerInput.uninstall_android_grab)
    pcall(PagerInput.uninstall_backend_hook)
end

----------------------------------------------------------------------------
-- 按键分发
----------------------------------------------------------------------------

--- 把 `GotoViewRel` 路由进阅读页。viewer 的 `onGotoViewRel` 只做转发，逻辑留在这里
--- 以便单元测试（viewer 模块会拉起整个 UI 栈，spec 里不能用）。
function Pager.view_rel(viewer, diff)
    local dir = tonumber(diff) or 0
    if viewer then
        if dir > 0 then
            viewer:onShowNextImage()
        elseif dir < 0 then
            viewer:onShowPrevImage()
        end
    end
    -- 始终消费：否则事件会继续下沉，翻到 ReaderUI 底下那本书。
    return true
end

--- Kamare 阅读页是不是最上层？盖着菜单/对话框时不吃键，
--- 否则绑定会抢走月读自己的菜单操作。
local function viewer_on_top(viewer)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or not UIManager or type(UIManager.getTopmostVisibleWidget) ~= "function" then
        return true
    end
    local ok2, top = pcall(function() return UIManager:getTopmostVisibleWidget() end)
    if not ok2 then return true end
    if top == viewer then return true end
    -- 刚设置完的一小段时间内，允许在提示框还挂着的时候按键（否则用户会以为没生效）。
    if state.gate_override_until and now() < state.gate_override_until then return true end
    -- Moon 在 Android 上可能把阅读页包在别的容器里，最上层拿到的是那个容器；
    -- 只要它「包含」阅读页，就算阅读页还在最上层。对话框/菜单不包含阅读页，
    -- 所以「盖着菜单时不翻页」这条依然成立。
    local ok3, matched = pcall(function()
        local util = require("ffi/util")
        return util.arrayReferences(top, viewer) ~= nil
    end)
    return ok3 and matched == true
end

--- 诊断用：阅读页现在算不算「在最上层」。
local function on_top_text()
    local viewer = active_viewer()
    if not viewer then return _("no pager page") end
    if viewer_on_top(viewer) then return _("yes") end
    return _("no (covered by another window)")
end

--- 记下这颗键最后怎么了：诊断页 + crash.log 共用，省得再靠猜。
local function note_result(text)
    state.last_result = text
    local entry = PagerInput.last_key
    if entry and entry.result == nil then entry.result = text end
end

--- 默认动作：只在 Kamare 阅读页里翻页；别处一律放行。
local function default_action(action)
    local viewer = active_viewer()
    if not viewer then return false end
    if not viewer_on_top(viewer) then
        -- 阅读页上面盖着东西：按键交给上层（月读菜单等），不翻背后的页。
        return false
    end
    local before = viewer._images_list_cur
    if action == "next" then
        viewer:onShowNextImage()
    elseif action == "prev" then
        viewer:onShowPrevImage()
    else
        return false
    end
    -- 翻页结果也记一行：按键收到了但页码没动，说明问题在阅读页那一侧
    -- （比如双页模式下取不到上一个跨页），而不是按键没接上。
    logger.info(string.format("[kamarepager] action=%s page %s -> %s",
        action, tostring(before), tostring(viewer._images_list_cur)))
    -- 第二个返回值：页码有没有真的动。第一页按「上一页」时不会动，
    -- 诊断页要能区分「键没收到」和「已经到头了」。
    return true, before ~= viewer._images_list_cur
end

-- 前置声明：捕获结束时要把嗅探关掉（定义在后面）。
local stop_capture_sniff

local function swallow_tail(fd, code)
    state.swallowing[tostring(fd) .. ":" .. tostring(code)] = true
end

--- `PagerInput` 的 handler：返回 true 表示这个事件已被吃掉。
---
--- 两种来源：
---   * Linux/Kindle/Kobo：翻页器自己的 evdev fd（`ev.fd` 能在 fd_path 里查到）
---   * Android：系统合成的事件没有 fd，码是 Android keycode
--- 后者只在用户**显式绑过**这个码时才处理，否则原样放行。
function Pager._dispatch(ev)
    if type(ev) ~= "table" then return false end
    local path = ev.fd and PagerInput.path_for_fd(ev.fd)
    if not path and not PagerInput.is_android() then return false end
    local id = ev.fd or "android"
    local code, value = ev.code, ev.value
    local slot = tostring(id) .. ":" .. tostring(code)

    if value == 1 then
        -- 绑定模式：下一个按下的键就是新的绑定，不翻页。
        if state.capture then
            if now() > state.capture.until_ts then
                state.capture = nil
            else
                local action = state.capture.action
                local callback = state.capture.callback
                state.capture = nil
                local ok, err = Pager.add_binding(action, code)
                if ok then
                    logger.info(string.format("[kamarepager] captured %s = %d", tostring(action), code))
                else
                    logger.warn(string.format("[kamarepager] capture %s = %d rejected: %s",
                        tostring(action), code, tostring(err)))
                end
                stop_capture_sniff()
                if ok then
                    note_result(T(_("bound to %1"), action == "next" and _("next page") or _("previous page")))
                else
                    note_result(T(_("binding rejected: %1"), tostring(err)))
                end
                if callback then pcall(callback, action, code, ok, err) end
                return true
            end
        end

        -- 一次物理按下只许翻一页：动作后 0.25 s 内从同一个来源来的按下丢掉。
        local guard = state.guard_until[id]
        if guard and now() < guard then
            swallow_tail(id, code)
            note_result(_("ignored (repeat within 0.25 s)"))
            return true
        end

        local action = state.action_by_code[code]
        local default_name
        if not action then
            -- 没显式绑定：按 KOReader 的键名兜底（LPgFwd/Down/Right → 下一页…）。
            action, default_name = PagerInput.default_action_for(code)
        end
        local payload = {
            action = action,
            code = code,
            value = value,
            fd = ev.fd,
            path = path,
        }
        if emit("key", payload) then
            state.guard_until[id] = now() + GUARD
            swallow_tail(id, code)
            note_result(_("handled by a dialog"))
            return true
        end
        if action then
            local applied, moved = default_action(action)
            if applied then
                state.guard_until[id] = now() + GUARD
                swallow_tail(id, code)
                if moved then
                    note_result(action == "next" and _("turned: next page") or _("turned: previous page"))
                else
                    note_result(_("no change (already at the first/last page)"))
                end
                return true
            end
            local reason = active_viewer()
                and _("pager page is covered by another window")
                or _("no pager page open")
            note_result(reason)
            logger.info("[kamarepager] key " .. tostring(code)
                .. " bound to " .. tostring(action) .. " but not applied: " .. reason)
            return false
        end
        -- 没绑定不代表没反应：KOReader 自己的 event_map 里可能就映射成了翻页
        -- （Android 的音量键 24/25、92/93 都是这样），交给原生路径。
        local passed = _("not bound")
        local ok_dev, dev = pcall(require, "device")
        if ok_dev and dev and dev.input and type(dev.input.event_map) == "table"
            and dev.input.event_map[code] then
            passed = _("not bound; handled by KOReader")
        end
        note_result(passed)
        return false
    end

    -- 松开 / 重复：只吃掉同一颗已被吃掉的键，避免两路信号各走一边。
    if state.swallowing[slot] then
        if value == 0 then state.swallowing[slot] = nil end
        return true
    end
    return false
end

----------------------------------------------------------------------------
-- 绑定（外部设置页用：月读「设置 → 阅读 → 翻页器」）
----------------------------------------------------------------------------

local CAPTURE_SECONDS = 15

local function save_bindings()
    local saved = read_settings()
    saved.next = copy_list(state.bindings.next)
    saved.prev = copy_list(state.bindings.prev)
    write_settings(saved)
end

--- 把存档里的值读成列表（兼容旧版存单个数字）。
local function read_list(value, fallback)
    if type(value) == "number" then return { value } end
    if type(value) == "table" then
        local out = {}
        for i = 1, #value do
            local code = tonumber(value[i])
            if code then out[#out + 1] = code end
        end
        if #out > 0 then return out end
    end
    return copy_list(fallback)
end

function Pager._load_bindings()
    local saved = read_settings()
    state.bindings.next = read_list(saved.next, DEFAULT_BINDINGS.next)
    state.bindings.prev = read_list(saved.prev, DEFAULT_BINDINGS.prev)
    state.action_by_code = build_action_map(state.bindings)
end

--- 当前绑定（列表的副本）。
function Pager.bindings()
    return {
        next = copy_list(state.bindings.next),
        prev = copy_list(state.bindings.prev),
    }
end

--- 给某个动作加一颗键。已经在别的动作上会先移走（不互换），
--- 已经在当前动作上返回 duplicate，超过 MAX_BINDINGS 返回 too_many。
function Pager.add_binding(action, code)
    if action ~= "next" and action ~= "prev" then
        return nil, "unknown_action", "unknown action: " .. tostring(action)
    end
    code = tonumber(code)
    if not code then
        return nil, "unknown_action", "code must be a number"
    end
    local list = state.bindings[action]
    for __, existing in ipairs(list) do
        if existing == code then
            return nil, "duplicate", "already bound to " .. action
        end
    end
    if #list >= MAX_BINDINGS then
        return nil, "too_many", "at most " .. MAX_BINDINGS .. " keys per action"
    end
    local other = action == "next" and "prev" or "next"
    local other_list = state.bindings[other]
    for i = #other_list, 1, -1 do
        if other_list[i] == code then table.remove(other_list, i) end
    end
    list[#list + 1] = code
    state.action_by_code = build_action_map(state.bindings)
    save_bindings()
    return true
end

--- 删掉某个动作上的一颗键（可以删到空）。
function Pager.remove_binding(action, code)
    if action ~= "next" and action ~= "prev" then
        return nil, "unknown_action"
    end
    code = tonumber(code)
    if not code then return nil, "unknown_action" end
    local list = state.bindings[action]
    local removed = false
    for i = #list, 1, -1 do
        if list[i] == code then
            table.remove(list, i)
            removed = true
        end
    end
    if not removed then return nil, "not_found" end
    state.action_by_code = build_action_map(state.bindings)
    save_bindings()
    return true
end

--- 恢复出厂绑定。
function Pager.reset_bindings()
    state.bindings = default_bindings()
    state.action_by_code = build_action_map(state.bindings)
    save_bindings()
    return true
end

function stop_capture_sniff()
    if state.capture_sniffed then
        state.capture_sniffed = nil
        pcall(PagerInput.stop_sniff)
    end
end

--- 进入「按一下要绑定的键」模式：下一次按键写进绑定，不翻页。
--- 回调参数 (action, code, ok, err)。seconds 后自动失效。
---
--- Linux 上会顺手开「全节点嗅探」：没被接管的节点本来收不到事件，
--- 不开的话「按键设置」永远等不到那颗键。
function Pager.begin_capture(action, callback, seconds)
    if action ~= "next" and action ~= "prev" then
        return nil, "unknown_action"
    end
    seconds = tonumber(seconds) or CAPTURE_SECONDS
    -- 万一 start() 在 Android 上被别的东西打断，这里补上：捕获必须能把键交给 _dispatch。
    PagerInput.set_handler(Pager._dispatch)
    PagerInput.install_hook()
    if not PagerInput.is_android() and not PagerInput.sniff_active() then
        local ok = PagerInput.start_sniff()
        if ok then state.capture_sniffed = true end
    end
    state.capture_seq = (state.capture_seq or 0) + 1
    local token = state.capture_seq
    state.capture = {
        action = action,
        callback = callback,
        token = token,
        until_ts = now() + seconds,
    }
    -- 到点自动收工（不能只在下一个按键时才检查，否则嗅探会一直开着）。
    pcall(function()
        require("ui/uimanager"):scheduleIn(seconds + 1, function()
            if state.capture and state.capture.token == token then
                local capture = state.capture
                state.capture = nil
                stop_capture_sniff()
                -- 让调用方知道"一颗键都没收到"，而不是静静结束。
                if capture.callback then
                    pcall(capture.callback, capture.action, nil, nil, "timeout")
                end
            end
        end)
    end)
    return true
end

function Pager.cancel_capture()
    state.capture = nil
    stop_capture_sniff()
    return true
end

function Pager.capture_active()
    return state.capture ~= nil and now() <= (state.capture.until_ts or 0)
end

----------------------------------------------------------------------------
-- 生命周期
----------------------------------------------------------------------------

function Pager.is_enabled()
    return state.enabled == true
end

--- Android 专用：KOReader 的输入层会把媒体键交还给系统，Lua 永远看不到。
--- 这里只接管「用户明确绑过」的码（以及绑定过程中按下的那一颗），其余媒体键
--- 继续留给系统，不抢系统音量/音乐控制。
local function android_wants(code)
    if not state.enabled then return false end
    -- 绑定模式：这颗键就是用来绑的，一定收。
    if Pager.capture_active() then return true end
    local action = state.action_by_code[code]
    if not action then return false end
    -- 只有现在真的会翻页才从系统手里拿走；盖着菜单/对话框时照旧放行。
    local viewer = active_viewer()
    return viewer ~= nil and viewer_on_top(viewer)
end

local function android_dispatch(code, value)
    PagerInput.feed{ code = code, value = value, media = true }
end

local function ensure_android_grab()
    if not PagerInput.is_android() then return true end
    -- 这段会碰 android.lib 这种 C 库对象，任何意外都不许把 Pager.start 带走。
    local ok, installed, err = pcall(PagerInput.install_android_grab,
        android_wants, android_dispatch)
    if not ok then
        logger.warn("[kamarepager] android media grab crashed: " .. tostring(installed))
        return false
    end
    if not installed and err ~= "not_android" then
        logger.warn("[kamarepager] android media grab not installed: " .. tostring(err))
    end
    return installed
end

--- 开始接管。幂等。
function Pager.start()
    if state.started then return true end
    local saved = read_settings()
    state.enabled = saved.enabled ~= false
    Pager._load_bindings()
    if not state.enabled then
        state.started = true
        return true
    end
    PagerInput.set_handler(Pager._dispatch)
    ensure_android_grab()
    PagerInput.set_notifier(function(event, dev) emit(event, dev) end)
    PagerInput.set_sniffer(function(entry) emit("key", entry) end)
    PagerInput.reset_flapping()
    PagerInput.attach()
    state.started = true
    return true
end

--- 用户关掉 / 打开总开关（内部接口，不在 capabilities 里）。
function Pager.set_enabled(enabled)
    enabled = enabled and true or false
    state.enabled = enabled
    local saved = read_settings()
    saved.enabled = enabled
    write_settings(saved)
    if enabled then
        PagerInput.reset_flapping()
        PagerInput.set_handler(Pager._dispatch)
        ensure_android_grab()
        PagerInput.attach()
    else
        PagerInput.detach()
    end
    return true
end

--- 「重新扫描」（内部接口）：清熔断后立刻重扫。
function Pager.rescan()
    if not state.enabled then return 0, 0 end
    PagerInput.reset_flapping()
    return PagerInput.rescan()
end

--- 阅读页打开 / 关闭：只在页面存活期间跑轻扫。
function Pager.watch_page()
    if not state.enabled then return end
    PagerInput.set_handler(Pager._dispatch)
    PagerInput.attach()
    PagerInput.start_loop()
end

function Pager.unwatch_page()
    PagerInput.stop_loop()
end

function Pager.on_resume()
    if not state.enabled then return end
    PagerInput.reset_flapping()
    PagerInput.attach()
end

----------------------------------------------------------------------------
-- 状态
----------------------------------------------------------------------------

function Pager.state_code()
    if not state.enabled then return "disabled" end
    local devices = PagerInput.devices()
    if PagerInput.is_flapping() then return "flapping" end
    if #devices == 0 then return "none" end
    for __, device in ipairs(devices) do
        if device.ours then return "attached" end
    end
    return "borrowed"
end

function Pager.status()
    return {
        state = Pager.state_code(),
        devices = PagerInput.devices(),
        last_error = PagerInput.last_error,
        last_key = PagerInput.last_key,
    }
end

--- 诊断用：阅读页收到的最后一次 KeyPress 键名（LPgBack / Down …）。
function Pager.note_keypress(name)
    state.last_keypress = tostring(name)
end

--- 最近一次从翻页器收到的按键（原始码，未绑定也记）。
function Pager.last_key()
    return PagerInput.last_key
end

--- 一行「最近按键」文案：排查某颗键没反应时，按一下再回来看这里。
function Pager.last_key_text()
    local key = PagerInput.last_key
    if not key then return _("No key received yet") end
    local action = state.action_by_code[key.code]
    local usage
    if action then
        usage = action == "next" and _("bound: next page") or _("bound: previous page")
    else
        usage = _("not bound")
    end
    return string.format("%d · %s · %s",
        tonumber(key.code) or -1, usage, tostring(key.name or key.path or "?"))
end

--- 诊断页正文：版本、状态、后端能力、绑定的键码、每个输入节点的判定结果。
--- 和 crash.log 里 `[kamarepager]` 那几行是同一份事实，方便直接截图。
function Pager.diagnose()
    local version = "?"
    pcall(function() version = require("kamareversion") end)
    local bindings = Pager.bindings()
    local lines = {
        string.format("kamare v%s · api %d", tostring(version), Pager.api_version),
        _("State") .. ": " .. tostring(Pager.state_code()),
        _("Enabled") .. ": " .. tostring(Pager.is_enabled()),
        _("Input backend") .. ": open=" .. tostring(PagerInput.can_open())
            .. " · handler=" .. tostring(PagerInput.handler_installed())
            .. " · hook=" .. tostring(PagerInput.hook_installed())
            .. (is_android() and (" · backend=" .. tostring(PagerInput.backend_hooked())) or "")
            .. (PagerInput.sniff_active() and " · sniffing" or "")
            .. (state.capture and (" · capture=" .. tostring(state.capture.action)) or ""),
        _("Keys") .. ": " .. _("next") .. "=" .. table.concat(bindings.next, ",")
            .. " " .. _("previous") .. "=" .. table.concat(bindings.prev, ","),
        _("Last key") .. ": " .. Pager.last_key_text(),
        _("Pager page on top") .. ": " .. on_top_text(),
        _("Last result") .. ": " .. tostring(state.last_result or _("none")),
        _("Key subscribers") .. ": " .. tostring(Pager.subscriber_count()),
    }
    -- 列出所有已绑定的码，方便确认「这颗键到底绑没绑」。
    local bound = {}
    for code, action in pairs(state.action_by_code) do
        bound[#bound + 1] = string.format("%d=%s", code, action)
    end
    table.sort(bound)
    lines[#lines + 1] = _("Bound codes") .. ": " .. table.concat(bound, " ")

    local recent = PagerInput.key_log or {}
    if #recent > 0 then
        lines[#lines + 1] = _("Recent keys") .. ":"
        for i = math.max(1, #recent - 9), #recent do
            local key = recent[i]
            lines[#lines + 1] = string.format("  code=%s value=%s  %s%s",
                tostring(key.code), tostring(key.value), tostring(key.name or key.path),
                key.result and (" · " .. tostring(key.result)) or "")
        end
    end
    if PagerInput.last_error then
        lines[#lines + 1] = _("Last error") .. ": " .. tostring(PagerInput.last_error)
    end
    if is_android() then
        lines[#lines + 1] = _("Android: no input node to take over; keys arrive directly.")
        lines[#lines + 1] = _("KOReader event") .. ": "
            .. tostring(PagerInput.last_passthrough or "-")
        lines[#lines + 1] = _("Reader KeyPress") .. ": "
            .. tostring(state.last_keypress or "-")
        lines[#lines + 1] = _("Android media grab") .. ": "
            .. (PagerInput.android_grab_installed() and "on" or "off")
            .. " · " .. tostring(PagerInput.android_grab_count())
            .. (PagerInput.android_grab_error()
                and (" · " .. tostring(PagerInput.android_grab_error())) or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("Input nodes") .. ":"
    for __, dev in ipairs(PagerInput.snapshot()) do
        local tags = {}
        if dev.blacklisted then tags[#tags + 1] = "blacklist" end
        if dev.pager then tags[#tags + 1] = "pager" end
        if dev.companion then tags[#tags + 1] = "companion" end
        if dev.adopted then tags[#tags + 1] = dev.ours and "adopted" or "borrowed" end
        if #tags == 0 then tags[#tags + 1] = "ignored" end
        local codes = dev.codes or {}
        local shown = {}
        for i = 1, math.min(#codes, 24) do shown[#shown + 1] = tostring(codes[i]) end
        lines[#lines + 1] = string.format("  %s  %s  [%s] keys=%s%s",
            dev.path, tostring(dev.name), table.concat(tags, ","),
            table.concat(shown, ","), #codes > 24 and "…" or "")
    end
    return table.concat(lines, "\n")
end

--- 把诊断写进一个固定路径的文件，方便「文件管理器里找出来发给别人」。
--- Android: /sdcard/koreader/kamare-pager.log；Kindle: /mnt/us/koreader/kamare-pager.log
function Pager.save_diagnostics()
    local ok, path = pcall(function()
        local DataStorage = require("datastorage")
        local target = DataStorage:getDataDir() .. "/kamare-pager.log"
        local file, err = io.open(target, "a")
        if not file then error(tostring(err or target)) end
        file:write("\n===== ", os.date("%Y-%m-%d %H:%M:%S"), " =====\n")
        file:write(Pager.diagnose(), "\n")
        local recent = PagerInput.key_log or {}
        file:write(_("Recent keys") .. " (" .. tostring(#recent) .. "):\n")
        for __, key in ipairs(recent) do
            file:write(string.format("  code=%s value=%s  %s  %s\n",
                tostring(key.code), tostring(key.value),
                tostring(key.path), tostring(key.name)))
        end
        file:close()
        return target
    end)
    if ok then return path end
    return nil, path
end

--- 诊断：临时嗅探**所有**输入节点 N 秒，结束后自动打开诊断页。
--- 用来回答「这颗键到底从哪个节点、以什么码发出来」。
function Pager.sniff_for(seconds)
    seconds = tonumber(seconds) or 30
    local ok, err = PagerInput.start_sniff()
    if not ok then
        -- Android 上没什么可嗅探的：键本来就直接到 KOReader，直接看诊断页。
        if err == "android" then
            Pager.show_diagnostics()
            return true
        end
        return nil, err
    end
    pcall(function()
        require("ui/uimanager"):scheduleIn(seconds, function()
            PagerInput.stop_sniff()
            Pager.show_diagnostics()
        end)
    end)
    return true
end

function Pager.sniff_stop()
    return PagerInput.stop_sniff()
end

--- 打开诊断对话框（按键时实时刷新）。Kamare 菜单与月读设置页共用。
--- 不算公开契约的一部分：UI 辅助，不在 capabilities 里。
function Pager.show_diagnostics()
    return pcall(function()
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")

        local subscriber
        local refreshing = false
        local show
        local function unsubscribe()
            if subscriber then Pager.off(subscriber) end
            subscriber = nil
        end

        show = function()
            unsubscribe()
            local box
            box = InfoMessage:new{
                text = Pager.diagnose() .. "\n\n"
                    .. _("Press a pager key to see its code.")
                    .. "\n" .. _("Keys are only logged while this page is open; close it to test page turning."),
                timeout = 60,
                dismiss_callback = unsubscribe,
            }
            -- 每按一次键重画一次；同时把按键吃掉（返回 true），
            -- 避免对话框背后跟着翻页。刷新走 scheduleIn：在输入回调里
            -- 直接 close/show 会动到 UIManager 的窗口栈，Android 上不稳。
            subscriber = Pager.on("key", function()
                if refreshing then return true end
                refreshing = true
                UIManager:scheduleIn(0.05, guarded("refresh diagnostics", function()
                    refreshing = false
                    unsubscribe()
                    UIManager:close(box)
                    show()
                end))
                return true
            end)
            UIManager:show(box)
        end

        show()
    end)
end

--- 两下设置：先按「下一页」那颗键，再按「上一页」那颗键。
--- 比「先选动作、再点添加」少绕一圈，也不会两次都绑到同一个动作上
--- （真机上就是这样：168 和 169 都被绑成了上一页，下一页永远是空的）。
function Pager.show_setup_wizard()
    return pcall(function()
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")

        local first_code
        local steps = {
            { action = "next", title = _("next page") },
            { action = "prev", title = _("previous page") },
        }
        local index = 1
        local ask

        local function finish()
            local list = Pager.bindings()
            -- 20 秒内不设闸门：提示框还在的时候按键也能翻页，方便立刻验证。
            state.gate_override_until = now() + 20
            UIManager:show(InfoMessage:new{
                text = T(_("Done: next = %1 · previous = %2"),
                    table.concat(list.next, ","), table.concat(list.prev, ","))
                    .. "\n" .. _("Press the two page keys now to try them."),
                timeout = 6,
            })
        end

        ask = function()
            local step = steps[index]
            if not step then finish() return end
            UIManager:show(InfoMessage:new{
                text = T(_("Press the %1 button now (15 seconds)."), step.title),
                timeout = 4,
            })
            Pager.begin_capture(step.action, function(_, code, ok, err)
                UIManager:scheduleIn(0.1, guarded("setup wizard", function()
                    if not ok then
                        local text
                        if err == "timeout" then
                            text = T(_("No key received in %1 seconds: this button never reaches KOReader."), 15)
                                .. "\n" .. _("Last key") .. ": " .. Pager.last_key_text()
                        else
                            text = T(_("Could not bind key %1 (%2)"), tostring(code), tostring(err))
                        end
                        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
                        return
                    end
                    if index == 2 and code == first_code then
                        UIManager:show(InfoMessage:new{
                            text = _("That is the same key as the next-page button. Press a different key."),
                            timeout = 4,
                        })
                        UIManager:scheduleIn(0.6, function() ask() end)
                        return
                    end
                    -- KOReader 自己认得、并且已经是翻页键的码（Android 的音量键等）：
                    -- 绑了也不会经过我们（兜底层不敢再翻一次），直接说清楚。
                    local mapped
                    do
                        local ok_dev, dev = pcall(require, "device")
                        if ok_dev and dev and dev.input and type(dev.input.event_map) == "table" then
                            mapped = dev.input.event_map[code]
                        end
                    end
                    if mapped == "LPgBack" or mapped == "LPgFwd"
                        or mapped == "RPgBack" or mapped == "RPgFwd" then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Key %1 already turns pages by itself; press another key."), code),
                            timeout = 4,
                        })
                        UIManager:scheduleIn(2.0, function() ask() end)
                        return
                    end
                    -- 「已经绑在这个动作上」不算失败：用户上次就配好了。
                    if index == 1 then first_code = code end
                    local added, add_err = Pager.add_binding(step.action, code)
                    local already = (not added) and add_err == "duplicate"
                    if not added and not already then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Could not bind key %1 (%2)"), code, tostring(add_err)),
                            timeout = 4,
                        })
                        return
                    end
                    UIManager:show(InfoMessage:new{
                        text = already
                            and T(_("%1 already uses key %2"), step.title, code)
                            or T(_("Bound %1 to key %2"), step.title, code),
                        timeout = 2,
                    })
                    index = index + 1
                    UIManager:scheduleIn(2.2, function() ask() end)
                end))
            end, 15)
        end

        ask()
    end)
end

--- 绑定编辑器（Kamare 侧唯一入口）。阅读页长按菜单和书库菜单都调它。
--- 列表模型：一个动作可以绑多颗键；点已有键 = 删除，另外提供添加/恢复默认。
function Pager.show_bindings()
    return pcall(function()
        local UIManager = require("ui/uimanager")
        local ButtonDialog = require("ui/widget/buttondialog")
        local InfoMessage = require("ui/widget/infomessage")

        local dialog
        local show_list

        local function close()
            if dialog then UIManager:close(dialog) end
            dialog = nil
        end

        local function codes_text(list)
            if not list or #list == 0 then return _("None") end
            local out = {}
            for __, code in ipairs(list) do out[#out + 1] = tostring(code) end
            return table.concat(out, " · ")
        end

        local function capture(action, title)
            close()
            Pager.begin_capture(action, function(_, code, ok, err)
                -- 从输入钩子里直接改界面太重，让这次按键先走完。
                UIManager:scheduleIn(0.1, guarded("capture result", function()
                    local text
                    if ok then
                        text = T(_("Bound %1 to key %2"), title, code)
                    elseif err == "duplicate" then
                        text = T(_("Key %1 is already bound to %2"), code, title)
                    elseif err == "timeout" then
                        text = T(_("No key received in %1 seconds: this button never reaches KOReader."), 15)
                    else
                        text = T(_("Could not bind key %1 (%2)"), code, tostring(err))
                    end
                    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
                    show_list(action, title)
                end))
            end, 15)
            UIManager:show(InfoMessage:new{
                text = T(_("Press the key for %1 now (15 seconds)."), title),
                timeout = 4,
            })
        end

        show_list = function(action, title)
            local list = Pager.bindings()[action]
            local buttons = {}
            for __, code in ipairs(list) do
                buttons[#buttons + 1] = {{
                    text = T(_("Remove key %1"), code),
                    callback = function()
                        Pager.remove_binding(action, code)
                        close()
                        show_list(action, title)
                    end,
                }}
            end
            buttons[#buttons + 1] = {{
                text = _("Add a key (press it now)"),
                callback = guarded("capture", function() capture(action, title) end),
            }}
            buttons[#buttons + 1] = {{
                text = _("Back"),
                callback = guarded("back to bindings", function()
                    close()
                    Pager.show_bindings()
                end),
            }}
            close()
            dialog = ButtonDialog:new{ title = title, buttons = buttons }
            UIManager:show(dialog)
        end

        local bindings = Pager.bindings()
        dialog = ButtonDialog:new{
            title = _("Pager keys"),
            buttons = {
                {{
                    text = _("Set up by pressing twice (next page, then previous)"),
                    callback = guarded("setup wizard", function()
                        close()
                        Pager.show_setup_wizard()
                    end),
                }},
                {{
                    text = T(_("Next page: %1"), codes_text(bindings.next)),
                    callback = guarded("next page list", function() show_list("next", _("Next page")) end),
                }},
                {{
                    text = T(_("Previous page: %1"), codes_text(bindings.prev)),
                    callback = guarded("prev page list", function() show_list("prev", _("Previous page")) end),
                }},
                {{
                    text = _("Reset to defaults"),
                    callback = guarded("reset bindings", function()
                        Pager.reset_bindings()
                        close()
                        Pager.show_bindings()
                    end),
                }},
            },
        }
        UIManager:show(dialog)
    end)
end

--- 一行可直接显示的状态文案（Moon 设置页 / Kamare 菜单共用）。
--- 末尾带插件版本：排查时能确认跑的是哪一版，而不是猜。
function Pager.describe()
    local version = "?"
    pcall(function() version = require("kamareversion") end)
    local code = Pager.state_code()
    local text
    if code == "disabled" then
        text = _("Pager is off")
    elseif code == "flapping" then
        text = _("Pager keeps disconnecting, reconnect paused")
    elseif is_android() and #PagerInput.devices() == 0 then
        -- Android 上键事件由系统直接送进 KOReader，没有可接管的 evdev 节点。
        text = _("Android: keys are delivered by the system")
    else
        local devices = PagerInput.devices()
        if #devices == 0 then
            text = _("No pager found")
        else
            local first = devices[1]
            local name = first.name or first.path
            if code == "borrowed" then
                text = T(_("Sharing %1 (taken over by another plugin)"), name)
            else
                text = T(_("Connected: %1"), name)
            end
        end
    end
    return text .. " · v" .. tostring(version)
end

return Pager
