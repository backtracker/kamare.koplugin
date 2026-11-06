-- Source-level wiring checks for the temporary manual page-join. Rendering is
-- exercised by the WSL acceptance run; these assertions catch accidental
-- removal/rename of the plumbing and, importantly, that the join stays
-- transient (no view_mode / configurable writes).

return function(t)
    local function read_src(name)
        local handle = io.open((t.spec_dir or "spec") .. "/../src/" .. name, "rb")
        if not handle then return "" end
        local body = handle:read("*a")
        handle:close()
        return body or ""
    end

    local viewer = read_src("kamareimageviewer.lua")
    local canvas = read_src("virtualpagecanvas.lua")

    ------------------------------------------------------------------------
    -- Trigger: down swipe in page mode only
    ------------------------------------------------------------------------
    t.ok(viewer:find('dir == "south" and self.view_mode == 0', 1, true) ~= nil,
        "JW1: down swipe is intercepted in page mode")
    t.ok(viewer:find("function KamareImageViewer:enterTempJoin", 1, true) ~= nil,
        "JW1: enterTempJoin exists")
    t.ok(viewer:find("function KamareImageViewer:exitTempJoin", 1, true) ~= nil,
        "JW1: exitTempJoin exists (down swipe toggles)")
    t.ok(viewer:find("self._temp_join then", 1, true) ~= nil,
        "JW1: an active join is checked before entering")

    ------------------------------------------------------------------------
    -- One-shot exit: next/prev skip the pair numerically
    ------------------------------------------------------------------------
    t.ok(viewer:find("function KamareImageViewer:_leaveTempJoin", 1, true) ~= nil,
        "JW2: leave helper exists")
    t.ok(viewer:find("return self:_leaveTempJoin(true)", 1, true) ~= nil,
        "JW2: next leaves the join")
    t.ok(viewer:find("return self:_leaveTempJoin(false)", 1, true) ~= nil,
        "JW2: prev leaves the join")
    t.ok(viewer:find("PageJoin.next_target", 1, true) ~= nil,
        "JW2: next target comes from the numeric plan")
    t.ok(viewer:find("PageJoin.prev_target", 1, true) ~= nil,
        "JW2: prev target comes from the numeric plan")

    ------------------------------------------------------------------------
    -- Transient: cleared by every layout change and lifecycle event
    ------------------------------------------------------------------------
    t.ok(viewer:find("function KamareImageViewer:_clearTempJoinState", 1, true) ~= nil,
        "JW3: clear helper exists")
    t.ok(viewer:find("function KamareImageViewer:switchToImageNum", 1, true) ~= nil,
        "JW3: page switching exists")
    t.ok(viewer:find("local had_join = self:_clearTempJoinState()", 1, true) ~= nil,
        "JW3: switchToImageNum clears a join")
    t.ok(viewer:find("self._temp_join = nil", 1, true) ~= nil,
        "JW3: close/document init drop the state")
    t.ok(viewer:find("function KamareImageViewer:onSetViewMode", 1, true) ~= nil,
        "JW3: view mode handler exists")
    t.ok(viewer:find("function KamareImageViewer:onSetPageDirection", 1, true) ~= nil,
        "JW3: page direction handler exists")
    t.ok(viewer:find("function KamareImageViewer:onSetWidePageMode", 1, true) ~= nil,
        "JW3: wide page handler exists")
    t.ok(viewer:find("function KamareImageViewer:onSetCropBorders", 1, true) ~= nil,
        "JW3: crop handler exists")
    -- All five layout setters call the clear helper.
    local clears = select(2, viewer:gsub("self:_clearTempJoinState%(%)", ""))
    t.ok(clears >= 5, "JW3: view/page/wide/split/crop setters clear the join")

    -- The join must not re-enter the persisted view-mode path.
    local join_start = viewer:find("function KamareImageViewer:enterTempJoin", 1, true)
    local join_end = viewer:find("function KamareImageViewer:exitTempJoin", 1, true)
    local enter_body = join_start and join_end and viewer:sub(join_start, join_end) or ""
    t.ok(enter_body ~= "", "JW4: enterTempJoin body is readable")
    t.ok(not enter_body:find("onSetViewMode", 1, true),
        "JW4: entering a join never changes view_mode")
    t.ok(not enter_body:find("configurable", 1, true),
        "JW4: entering a join never writes configurable")

    ------------------------------------------------------------------------
    -- Canvas: a dedicated paint branch before the normal view dispatch
    ------------------------------------------------------------------------
    t.ok(canvas:find("local PageJoin = require", 1, true) ~= nil,
        "JW5: canvas uses the pure plan module")
    t.ok(canvas:find("temp_join = nil", 1, true) ~= nil,
        "JW5: canvas owns transient join state")
    t.ok(canvas:find("function VirtualPageCanvas:setTempJoin", 1, true) ~= nil,
        "JW5: setter exists")
    t.ok(canvas:find("function VirtualPageCanvas:clearTempJoin", 1, true) ~= nil,
        "JW5: clearer exists")
    t.ok(canvas:find("if self.temp_join then", 1, true) ~= nil,
        "JW5: paint dispatch checks the join first")
    t.ok(canvas:find("function VirtualPageCanvas:paintTempJoin", 1, true) ~= nil,
        "JW5: paint dispatcher exists")
    t.ok(canvas:find("function VirtualPageCanvas:paintSplitJoin", 1, true) ~= nil,
        "JW5: split painter exists")
    t.ok(canvas:find("function VirtualPageCanvas:paintPairJoin", 1, true) ~= nil,
        "JW5: pair painter exists")
    t.ok(canvas:find("function VirtualPageCanvas:_paintJoinPage", 1, true) ~= nil,
        "JW5: shared page blitter exists")
    t.ok(canvas:find("PageJoin.split_layout", 1, true) ~= nil,
        "JW5: split zoom comes from the pure plan module")
    t.ok(canvas:find("PageJoin.pair_pages", 1, true) ~= nil,
        "JW5: pair display order comes from the pure plan module")
    t.ok(canvas:find("and not self.temp_join", 1, true) ~= nil,
        "JW5: the magnifier is not painted over a join")

    ------------------------------------------------------------------------
    -- Visible-page protection and gesture coexistence
    ------------------------------------------------------------------------
    t.ok(viewer:find("if self._temp_join then", 1, true) ~= nil,
        "JW6: viewer checks the join in gesture/navigation paths")
    t.ok(viewer:find("if plan.first and plan.first > 0", 1, true) ~= nil,
        "JW6: both joined pages are protected from eviction")
    t.ok(viewer:find("if self._temp_join then return false end", 1, true) ~= nil,
        "JW6: the long-press magnifier is disabled over a join")
end
