-- Pager takeover + public facade.
--
-- Covers decisions 01-03 (A1-A16 in issues/05-acceptance.md) with a fake
-- evdev layer: no real device, no /proc, no uinput.

local PagerInput = require("kamarepager_input")
local Pager = require("kamarepager")

-- B: KEY= bitmaps. Words are most-significant-first, which is the part that is
-- easy to get backwards; the multi-word sample is copied from a real keyboard.
local KEY_109 = "200000000000 0"          -- bit 109 = PgDn
local KEY_104 = "10000000000 0"           -- bit 104 = PgUp
local KEY_70 = "40 0"                     -- bit 70 = ScrollLock
local KEY_NONE = "0"
local KEY_REAL = "402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe"

local function block(name, event, key, opts)
    opts = opts or {}
    local phys = opts.phys
    if not phys then phys = "phys-" .. (event ~= "" and event or name) end
    return table.concat({
        "I: Bus=0005 Vendor=0000 Product=0000 Version=0000",
        string.format('N: Name="%s"', name),
        "P: Phys=" .. phys,
        "S: Sysfs=/devices/virtual/input/input9",
        "U: Uniq=" .. (opts.uniq or ""),
        string.format("H: Handlers=%s ", event),
        "B: PROP=0",
        "B: EV=120013",
        "B: KEY=" .. key,
        "",
    }, "\n")
end

--- B: KEY= 位图（两字，高位字在前）。用来造 114/115 这类测试位图，
--- 免得手算十六进制出错。
local function keymap(codes)
    local function word(base)
        local nibble = {}
        for i = 1, 16 do nibble[i] = 0 end
        for __, code in ipairs(codes) do
            local bit = code - base
            if bit >= 0 and bit < 64 then
                local index = 16 - math.floor(bit / 4)
                nibble[index] = nibble[index] + 2 ^ (bit % 4)
            end
        end
        local out = {}
        for i = 1, 16 do out[i] = string.format("%x", nibble[i]) end
        return table.concat(out)
    end
    return word(64) .. " " .. word(0)
end

local function make_input()
    local inp = {
        event_map = {},
        opened_devices = {},
        links = {},
        opens = 0,
        closed = {},
    }
    function inp.open(self, path, name)
        inp.opens = inp.opens + 1
        local fd = 100 + inp.opens
        inp.opened_devices[path] = fd
        inp.links[fd] = path
        inp.last_name = name
        return fd
    end
    function inp.close(self, path)
        local fd = inp.opened_devices[path]
        inp.closed[#inp.closed + 1] = path
        inp.opened_devices[path] = nil
        if fd then inp.links[fd] = nil end
        return true
    end
    function inp.handleKeyBoardEv(self, ev) return { passed = ev } end
    return inp
end

local function setup(t, opts)
    opts = opts or {}
    local inp = make_input()
    local clock = opts.clock or 1000
    PagerInput.set_deps{
        device = { input = inp },
        input = inp,
        now = function() return clock end,
        schedule = function() return true end,
        read_proc = function() return opts.proc or "" end,
        readlink = function(fd) return inp.links[fd] end,
    }
    PagerInput.opened = {}
    PagerInput.fd_path = {}
    PagerInput._blocked = {}
    PagerInput._closes = {}
    PagerInput.last_error = nil
    PagerInput.last_key = nil
    PagerInput.keys_seen = 0
    PagerInput.set_handler(nil)
    PagerInput.set_notifier(nil)
    PagerInput.uninstall_hook()
    Pager._reset()
    return inp
end

return function(t)
    ------------------------------------------------------------------------
    -- A1-A3: scan filtering
    ------------------------------------------------------------------------
    PagerInput.set_deps(nil)
    local proc = block("bd71828-pwrkey", "event0", KEY_109)
        .. block("goodix-ts", "event1", KEY_109)
        .. block("bma4xy", "event2", KEY_109)
        .. block("wacom-digitizer", "event3", KEY_109)
        .. block("pt_mt", "event4", KEY_109)
        .. block("KHP Keyboard", "event5", KEY_109)
    local found = PagerInput.candidates(proc)
    t.eq(#found, 1, "A1: only the pager survives the blacklist")
    t.eq(found[1].path, "/dev/input/event5", "A1: pager path parsed from Handlers")

    t.eq(#PagerInput.candidates(block("NoEvent", "", KEY_109)), 0,
        "A2: a device without an event node is skipped")
    t.eq(#PagerInput.candidates(block("KHP Keyboard", "event5", KEY_NONE)), 0,
        "A3: no pager key code -> not a pager")
    t.eq(#PagerInput.candidates(block("KHP Keyboard", "event5", KEY_70)), 1,
        "A3: ScrollLock alone is enough")

    t.ok(PagerInput.key_bit_set(KEY_REAL, 109), "A3: real bitmap, PgDn set")
    t.ok(not PagerInput.key_bit_set(KEY_REAL, 0), "A3: real bitmap, bit 0 clear")
    t.ok(PagerInput.key_bit_set(KEY_REAL, 1), "A3: real bitmap, bit 1 set")
    t.ok(PagerInput.key_bit_set(KEY_104, 104), "A3: single high-word bit")
    t.ok(not PagerInput.key_bit_set(KEY_104, 109), "A3: neighbouring bit stays clear")
    t.ok(not PagerInput.key_bit_set(KEY_104, 40), "A3: no false positive on the low word")

    ------------------------------------------------------------------------
    -- A1b: 一台翻页器占多个 event 节点（键盘 + 用户控制/音量）时一起接管
    ------------------------------------------------------------------------
    local pager_phys = "58:2b:be:f5:8c:78"
    local two_nodes = block("Beauty-R1", "event20", KEY_109, { phys = pager_phys })
        .. block("Beauty-R1 Consumer Control", "event21", keymap{ 114, 115 }, { phys = pager_phys })
    local siblings = PagerInput.candidates(two_nodes)
    t.eq(#siblings, 2, "A1b: every node of one pager is adopted")
    t.eq(siblings[1].path, "/dev/input/event20", "A1b: keyboard node first")
    t.eq(siblings[2].path, "/dev/input/event21", "A1b: companion node adopted too")
    t.ok(PagerInput.key_bit_set(keymap{ 115 }, 115), "A1b: keymap helper builds bit 115")
    t.ok(not PagerInput.key_bit_set(keymap{ 115 }, 114), "A1b: neighbouring bit stays clear")

    local declared = PagerInput.key_codes(KEY_104)
    local has104, has109 = false, false
    for __, code in ipairs(declared) do
        if code == 104 then has104 = true elseif code == 109 then has109 = true end
    end
    t.ok(has104 and not has109 and #declared > 0, "A1b: key_codes lists exactly what the node declares")

    t.eq(#PagerInput.candidates(block("Speaker", "event30", keymap{ 114, 115 })), 0,
        "A1b: a volume-only device is not a pager")
    t.eq(#PagerInput.candidates(block("Beauty-R1", "event20", KEY_109, { phys = pager_phys })
        .. block("Beauty-R1 power key", "event22", keymap{ 116 }, { phys = pager_phys })), 1,
        "A1b: a blacklisted sibling stays untouched")
    t.eq(#PagerInput.candidates(block("A", "event40", KEY_109, { phys = "p1", uniq = "aa:bb" })
        .. block("B", "event41", keymap{ 115 }, { phys = "p2", uniq = "aa:bb" })), 2,
        "A1b: Uniq groups nodes that report different Phys")

    ------------------------------------------------------------------------
    -- A4/A5: event_map merge
    ------------------------------------------------------------------------
    local inp = setup(t)
    inp.event_map[109] = "LPgBack"       -- another plugin's mapping wins
    PagerInput.merge_event_map()
    t.eq(inp.event_map[109], "LPgBack", "A4: existing mapping is never overwritten")
    t.eq(inp.event_map[104], "LPgBack", "A5: PageUp maps like KOReader does")
    t.eq(inp.event_map[70], "ScrollLock", "A5: ScrollLock mapped")
    t.eq(inp.event_map[109], "LPgBack", "A5: the planted value survives")
    PagerInput.merge_event_map()
    t.eq(inp.event_map[104], "LPgBack", "A6: merging twice is idempotent")

    ------------------------------------------------------------------------
    -- A6: attach is idempotent
    ------------------------------------------------------------------------
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    PagerInput.attach()
    PagerInput.attach()
    t.eq(inp.opens, 1, "A6: attach opens the device once")
    t.eq(#PagerInput.devices(), 1, "A6: one device recorded")

    ------------------------------------------------------------------------
    -- A7/A8: liveness is a path comparison, not "(deleted)"
    ------------------------------------------------------------------------
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    PagerInput.attach()
    local fd = PagerInput.devices()[1].fd
    t.eq(PagerInput.prune(), 0, "A7: a matching readlink target stays attached")
    inp.links[fd] = "/dev/null"          -- fd number reused by an unrelated file
    t.eq(PagerInput.prune(), 1, "A8: a reused fd number is detected as dead")
    t.is_nil(inp.opened_devices["/dev/input/event5"], "A8: stale registry entry cleared")
    t.eq(#PagerInput.devices(), 0, "A8: no devices left")

    ------------------------------------------------------------------------
    -- A9: borrow instead of stealing
    ------------------------------------------------------------------------
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    inp.opened_devices["/dev/input/event5"] = 77
    inp.links[77] = "/dev/input/event5"
    PagerInput.attach()
    local devices = PagerInput.devices()
    t.eq(#devices, 1, "A9: borrowed device is recorded")
    t.eq(devices[1].fd, 77, "A9: the owner's fd is used")
    t.ok(devices[1].ours == false, "A9: marked as borrowed")
    t.eq(inp.opens, 0, "A9: we never open a device someone else owns")

    -- A10: a throwing open() must not escape
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    inp.open = function() error("boom") end
    local ok = pcall(PagerInput.attach)
    t.ok(ok, "A10: a failing open does not raise")
    t.eq(#PagerInput.devices(), 0, "A10: nothing attached")
    t.ok(PagerInput.last_error ~= nil, "A10: the failure is recorded")

    ------------------------------------------------------------------------
    -- A11/A12: dedupe window and flapping circuit breaker
    ------------------------------------------------------------------------
    local clock = 1000
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    PagerInput.set_deps{ now = function() return clock end }
    local turns = 0
    Pager.set_deps{
        now = function() return clock end,
        viewer = function()
            return { onShowNextImage = function() turns = turns + 1 end,
                     onShowPrevImage = function() end }
        end,
    }
    PagerInput.attach()
    local pfd = PagerInput.devices()[1].fd
    t.ok(Pager._dispatch{ fd = pfd, code = 109, value = 1 }, "A11: first press consumed")
    t.eq(turns, 1, "A11: one page turn")
    clock = 1000.1
    t.ok(Pager._dispatch{ fd = pfd, code = 109, value = 1 }, "A11: duplicate press swallowed")
    t.eq(turns, 1, "A11: still one page turn")
    clock = 1000.5
    t.ok(Pager._dispatch{ fd = pfd, code = 109, value = 1 }, "A11: press after the window passes")
    t.eq(turns, 2, "A11: second page turn")
    t.ok(not Pager._dispatch{ fd = 999, code = 109, value = 1 },
        "A11: a non-pager fd is never consumed")

    -- flapping: three deaths inside the window block further reopens
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    PagerInput.set_deps{ now = function() return 2000 end }
    for _i = 1, 3 do
        PagerInput.attach()
        local rec = PagerInput.devices()[1]
        inp.links[rec.fd] = nil
        PagerInput.prune()
    end
    t.ok(PagerInput.is_flapping(), "A12: three deaths trip the breaker")
    local before = inp.opens
    PagerInput.attach()
    t.eq(inp.opens, before, "A12: no reopen while flapping")
    PagerInput.reset_flapping()
    PagerInput.attach()
    t.eq(inp.opens, before + 1, "A12: rescan after reset reopens")

    ------------------------------------------------------------------------
    -- A13/A14: subscriber order, payload and fd scoping
    ------------------------------------------------------------------------
    inp = setup(t, { proc = block("KHP Keyboard", "event5", KEY_109) })
    clock = 3000
    Pager.set_deps{
        now = function() return clock end,
        viewer = function() return nil end,
    }
    local seen = {}
    Pager.on("key", function(ev) seen[#seen + 1] = "first:" .. tostring(ev.code) end)
    local newest = Pager.on("key", function(ev)
        seen[#seen + 1] = "second:" .. tostring(ev.action)
        return ev.code == 109
    end)
    t.ok(newest ~= nil, "A13: on() returns a handle")
    PagerInput.attach()
    local pfd = PagerInput.devices()[1].fd
    t.ok(Pager._dispatch{ fd = pfd, code = 109, value = 1 }, "A13: newest subscriber consumes")
    t.eq(#seen, 1, "A13: the older subscriber never ran")
    t.eq(seen[1], "second:next", "A13: action is resolved for bound codes")

    Pager.off(newest)
    seen = {}
    clock = 3001
    t.ok(not Pager._dispatch{ fd = pfd, code = 70, value = 1 },
        "A14: unbound code, nobody consumed")
    t.eq(seen[1], "first:70", "A14: unbound code still delivered")
    t.ok(not Pager._dispatch{ fd = pfd, code = 109, value = 1 },
        "A14: without a viewer even a bound key is passed through")

    -- hook: only the pager's own fd reaches the handler
    local handled = 0
    PagerInput.set_handler(function() handled = handled + 1 return true end)
    PagerInput.install_hook()
    inp.handleKeyBoardEv(inp, { fd = pfd, code = 109, value = 1 })
    t.eq(handled, 1, "A14: pager fd reaches the handler")

    -- 钩子现在对每个按键都会问一次门面（Android 的键没有 fd，必须靠这条路径），
    -- 但门面自己只处理翻页器的 fd：外部 fd 必须原样放行。
    PagerInput.set_handler(Pager._dispatch)
    local passed = inp.handleKeyBoardEv(inp, { fd = 4242, code = 109, value = 1 })
    t.ok(passed and passed.passed, "A14: foreign fd is passed through by the facade")

    ------------------------------------------------------------------------
    -- A17: 绑定是列表 —— 添加/删除/冲突/上限/捕获
    ------------------------------------------------------------------------
    inp = setup(t, { proc = block("Beauty-R1", "event20", KEY_109) })
    local prev_turns, next_turns = 0, 0
    local now_ts = 5000
    Pager.set_deps{
        now = function() return now_ts end,
        viewer = function()
            return { onShowNextImage = function() next_turns = next_turns + 1 end,
                     onShowPrevImage = function() prev_turns = prev_turns + 1 end }
        end,
    }
    Pager.reset_bindings()
    PagerInput.attach()
    PagerInput.set_handler(Pager._dispatch)
    PagerInput.install_hook()
    local kfd = PagerInput.devices()[1].fd

    -- 出厂只有 109/104：别的键一律放行（不再有"猜出来的"备用码）
    t.eq(#Pager.bindings().next, 1, "A17: next starts with a single code")
    t.eq(Pager.bindings().next[1], 109, "A17: next defaults to 109")
    t.ok(inp.handleKeyBoardEv(inp, { fd = kfd, code = 115, value = 1 }) ~= nil,
        "A17: an unbound volume key is passed through")

    -- 加一颗键就生效
    t.ok(Pager.add_binding("prev", 115), "A17: add_binding(prev, 115)")
    t.ok(inp.handleKeyBoardEv(inp, { fd = kfd, code = 115, value = 1 }) == nil,
        "A17: the new binding is consumed")
    t.eq(prev_turns, 1, "A17: the new binding turns the page back")
    t.eq(PagerInput.last_key.code, 115, "A17: the last key code is recorded")

    -- 重复添加同一个动作里的码 → duplicate
    local ok, err = Pager.add_binding("prev", 115)
    t.is_nil(ok, "A17: duplicate code is rejected")
    t.eq(err, "duplicate", "A17: duplicate is reported")

    -- 加到另一个动作 → 从原动作移走（不是互换）
    t.ok(Pager.add_binding("next", 115), "A17: moving a code to another action")
    t.eq(#Pager.bindings().prev, 1, "A17: the code was removed from prev")
    t.eq(Pager.bindings().prev[1], 104, "A17: prev keeps its default code")
    t.eq(#Pager.bindings().next, 2, "A17: next now has two codes")

    -- 删除
    t.ok(Pager.remove_binding("next", 115), "A17: remove_binding")
    t.eq(#Pager.bindings().next, 1, "A17: the code is gone")
    t.is_nil((Pager.remove_binding("next", 115)), "A17: removing twice reports not_found")
    t.eq(select(2, Pager.remove_binding("next", 115)), "not_found", "A17: not_found is reported")

    -- 上限（先把默认的 109 摘掉，列表从空开始）
    Pager.reset_bindings()
    Pager.remove_binding("next", 109)
    for code = 200, 207 do
        t.ok(Pager.add_binding("next", code), "A17: filling up to the limit (" .. code .. ")")
    end
    local too_many, why = Pager.add_binding("next", 208)
    t.is_nil(too_many, "A17: the list is capped")
    t.eq(why, "too_many", "A17: too_many is reported")

    -- 捕获：下一次按键写进绑定，且不翻页
    Pager.reset_bindings()
    local captured_action, captured_code
    now_ts = 6000
    Pager.begin_capture("next", function(action, code)
        captured_action, captured_code = action, code
    end, 10)
    local before_next = next_turns
    t.ok(inp.handleKeyBoardEv(inp, { fd = kfd, code = 118, value = 1 }) == nil,
        "A17: the capture press is consumed")
    t.eq(captured_action, "next", "A17: capture reports the action")
    t.eq(captured_code, 118, "A17: capture reports the code")
    t.eq(next_turns, before_next, "A17: capturing does not turn a page")
    t.eq(#Pager.bindings().next, 2, "A17: the captured key was appended")

    -- 未知码不吞
    now_ts = 7000
    t.ok(inp.handleKeyBoardEv(inp, { fd = kfd, code = 200, value = 1 }) ~= nil,
        "A17: an unknown code is not swallowed")
    t.eq(PagerInput.last_key.code, 200, "A17: even an unknown code is recorded for diagnosis")
    Pager.cancel_capture()
    Pager.reset_bindings()

    ------------------------------------------------------------------------
    -- A15: bindings() is a copy
    ------------------------------------------------------------------------
    Pager.reset_bindings()
    local bindings = Pager.bindings()
    bindings.next[1] = 1
    t.eq(Pager.bindings().next[1], 109, "A15: mutating the copy changes nothing")

    ------------------------------------------------------------------------
    -- A16: GotoViewRel routed into the viewer
    ------------------------------------------------------------------------
    -- The viewer module pulls in the whole UI stack (fontlist, device), so the
    -- routing lives in the facade and the viewer only forwards to it. Check the
    -- forwarding exists in the source, and test the routing itself here.
    local lfs = require("libs/libkoreader-lfs")
    local viewer_path = (t.spec_dir or "spec") .. "/../src/kamareimageviewer.lua"
    local handle = io.open(viewer_path, "rb")
    local viewer_source = handle and handle:read("*a") or ""
    if handle then handle:close() end
    t.ok(viewer_source:find("function KamareImageViewer:onGotoViewRel", 1, true) ~= nil,
        "A16: the viewer implements onGotoViewRel")
    t.ok(viewer_source:find("Pager.view_rel(self, diff)", 1, true) ~= nil,
        "A16: the viewer delegates to Pager.view_rel")

    local calls = {}
    local fake = {
        onShowNextImage = function() calls[#calls + 1] = "next" end,
        onShowPrevImage = function() calls[#calls + 1] = "prev" end,
    }
    t.ok(Pager.view_rel(fake, 1) == true, "A16: GotoViewRel is consumed")
    t.eq(calls[1], "next", "A16: +1 turns forward")
    Pager.view_rel(fake, -1)
    t.eq(calls[2], "prev", "A16: -1 turns back")
    t.ok(Pager.view_rel(nil, 1) == true, "A16: consumed even with no viewer")
    t.eq(#calls, 2, "A16: no viewer, no call")

    ------------------------------------------------------------------------
    -- status text
    ------------------------------------------------------------------------
    t.eq(Pager.status().state, "attached", "status: attached after takeover")
    t.ok(type(Pager.describe()) == "string", "status: describe() returns text")
    Pager.set_enabled(false)
    t.eq(Pager.status().state, "disabled", "status: disabled once the switch is off")
    t.eq(#PagerInput.devices(), 0, "status: disabling releases the device")
    Pager.set_enabled(true)
    t.eq(Pager.status().state, "attached", "status: re-enabling reattaches immediately")
    PagerInput.detach()
    t.eq(Pager.status().state, "none", "status: none after detach")
    t.ok(not PagerInput.loop_active(), "detach stops the rescan loop")

    ------------------------------------------------------------------------
    -- A18: Android —— 键事件没有 fd，键码是 Android keycode
    ------------------------------------------------------------------------
    inp = setup(t)
    PagerInput.set_deps{
        device = { input = inp, isAndroid = function() return true end },
    }
    Pager._reset()
    PagerInput.merge_event_map()
    t.eq(inp.event_map[85], "LPgFwd", "A18: Android media play/pause pages forward")
    t.is_nil(inp.event_map[104], "A18: Linux evdev codes are not merged on Android")
    inp.event_map[87] = "LPgFwd"
    t.eq(inp.event_map[87], "LPgFwd", "A18: an existing Android mapping is kept")

    PagerInput.set_handler(Pager._dispatch)
    PagerInput.install_hook()
    inp.handleKeyBoardEv(inp, { code = 85, value = 1 })
    t.eq(PagerInput.last_key.code, 85, "A18: a key without an fd is still recorded")
    t.eq(PagerInput.last_key.name, "Android", "A18: recorded with the Android source tag")

    ------------------------------------------------------------------------
    -- A19: Android 媒体键 —— KOReader 把它们 return 0 丢给系统，
    -- 这里在 AInputQueue_finishEvent 上把它们捞回来。
    ------------------------------------------------------------------------
    inp = setup(t)
    local handled_seen = {}
    local fake_lib = {
        AInputEvent_getType = function(ev) return ev.type end,
        AKeyEvent_getAction = function(ev) return ev.action end,
        AKeyEvent_getKeyCode = function(ev) return ev.code end,
        AInputQueue_finishEvent = function(_, _, handled)
            handled_seen[#handled_seen + 1] = handled
            return 0
        end,
    }
    local android = { lib = fake_lib }
    local pending, dispatched = {}, {}
    PagerInput.set_deps{
        device = { input = inp, isAndroid = function() return true end },
        input = inp,
        android = android,
        schedule = function(_, fn) pending[#pending + 1] = fn return true end,
    }
    Pager._reset()

    local want = function(code) return code == 87 end
    local ok, err = PagerInput.install_android_grab(want, function(code, value)
        dispatched[#dispatched + 1] = { code = code, value = value }
    end)
    t.ok(ok, "A19: grab installed (" .. tostring(err) .. ")")
    t.ok(PagerInput.android_grab_installed(), "A19: grab reports installed")
    t.ok(android.lib ~= fake_lib, "A19: android.lib is wrapped")
    t.eq(android.lib.AInputEvent_getType({ type = 2 }), 2,
        "A19: other android.lib calls still reach the real library")

    android.lib.AInputQueue_finishEvent("q", { type = 1, action = 0, code = 87 }, 0)
    t.eq(handled_seen[1], 1, "A19: a swallowed media key is taken from the system")
    t.eq(#dispatched, 0, "A19: dispatch is deferred out of the input callback")
    t.eq(#pending, 1, "A19: one drain scheduled")
    pending[1]()
    t.eq(#dispatched, 1, "A19: key dispatched after the callback")
    t.eq(dispatched[1].code, 87, "A19: dispatched the captured code")
    t.eq(dispatched[1].value, 1, "A19: dispatched the press")

    android.lib.AInputQueue_finishEvent("q", { type = 1, action = 1, code = 87 }, 0)
    t.eq(handled_seen[2], 1, "A19: the matching release is taken too")
    t.eq(PagerInput.android_grab_count(), 2, "A19: grab counter counts both")

    android.lib.AInputQueue_finishEvent("q", { type = 1, action = 0, code = 24 }, 0)
    t.eq(handled_seen[3], 0, "A19: keys we did not ask for stay with the system")
    android.lib.AInputQueue_finishEvent("q", { type = 2, action = 0, code = 87 }, 0)
    t.eq(handled_seen[4], 0, "A19: motion events are untouched")

    t.ok(PagerInput.uninstall_android_grab(), "A19: uninstall")
    t.ok(android.lib == fake_lib, "A19: uninstall restores android.lib")

    -- 门面启动时自动装上（Android）。
    Pager.reset_bindings()
    Pager.start()
    t.ok(PagerInput.android_grab_installed(), "A19: Pager.start installs the grab on Android")
    Pager._reset()

    ------------------------------------------------------------------------
    -- A20: 钩子被别的插件换掉 —— 自愈 + 输入后端兜底
    ------------------------------------------------------------------------
    inp = setup(t)
    inp.event_map = { [24] = "LPgBack" }
    local current_events = {
        { type = 1, code = 168, value = 1 },
        { type = 1, code = 24, value = 1 },
        { type = 3, code = 0, value = 0 },
    }
    inp.input = {
        waitForEvent = function() return true, current_events end,
    }
    PagerInput.set_deps{ device = { input = inp, isAndroid = function() return true end }, input = inp }

    -- 自愈：hook_installed() 必须看「现在链子上的是不是我们」。
    PagerInput.install_hook()
    t.ok(PagerInput.hook_installed(), "A20: hook installed")
    local foreign = function() return "foreign" end
    inp.handleKeyBoardEv = foreign
    t.ok(not PagerInput.hook_installed(), "A20: a replaced hook is reported as missing")
    t.ok(PagerInput.install_hook(), "A20: install_hook repairs a replaced hook")
    t.ok(PagerInput.hook_installed(), "A20: hook is live again")
    inp.handleKeyBoardEv = foreign
    t.ok(not PagerInput.hook_installed(), "A20: replaced again")

    -- 兜底：钩子不在链上时，从输入后端出口补位。
    local seen = {}
    PagerInput.set_handler(function(ev)
        seen[#seen + 1] = ev.code
        return false
    end)
    t.ok(PagerInput.install_backend_hook(), "A20: backend hook installed")
    t.ok(PagerInput.backend_hooked(), "A20: backend hook reports hooked")
    PagerInput.last_key = nil
    PagerInput.key_log = {}
    local ok_backend, evs = inp.input.waitForEvent(0, 0)
    t.ok(ok_backend, "A20: backend returns")
    t.eq(#evs, 3, "A20: events are passed through untouched")
    t.eq(#seen, 2, "A20: the backend feeds every key (Kamare pages by itself)")
    t.eq(seen[1], 168, "A20: first key dispatched")
    t.eq(seen[2], 24, "A20: a KOReader-mapped key is dispatched too")
    t.eq(PagerInput.last_key.code, 24, "A20: last key recorded")
    t.eq(#PagerInput.key_log, 2, "A20: both keys logged")

    -- 同一颗事件即使钩子也走一遍，也只能处理一次（后端打标记）。
    local one = { type = 1, code = 168, value = 1 }
    current_events = { one }
    seen = {}
    inp.input.waitForEvent(0, 0)
    t.eq(#seen, 1, "A20: backend feeds the event once")
    instr_wired = PagerInput.install_hook()
    t.ok(instr_wired, "A20: hook installed for the dedupe check")
    PagerInput.dispatch(inp, one)
    t.eq(#seen, 1, "A20: the hook skips an event the backend already fed")

    PagerInput.uninstall_backend_hook()
    t.ok(not PagerInput.backend_hooked(), "A20: backend hook removed")
    Pager._reset()
end
