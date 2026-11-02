--[[--
月读扩展登记：把「翻页器」放进月读设置的「阅读」组（`ext.kamare`）。

Kamare 的翻页器接管默认就是开的、零配置可用，这一页只做三件事：
看到当前状态、关掉/打开总开关、手动重新扫描。

设置值存在 KOReader 的 `G_reader_settings.kamarepager`，和插件自身读的是同一份。
没装月读时这个文件不会被读；装了就由月读的扩展机制自动挂进设置树。
--]]

local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
if dir and not package.path:find(dir, 1, true) then
    package.path = dir .. "/?.lua;" .. package.path
end

local function settingEntries(desktop)
    local Row = require("ui.themes.widgets.row")
    local Pager = require("kamarepager")
    local _ = require("gettext")
    local T = require("ffi/util").template

    local function statusRow(iw)
        return Row.widget({
            width = iw,
            icon = "bluetooth",
            title = _("Pager"),
            subtitle = Pager.describe(),
            chevron = false,
        })
    end

    local function toggleRow(iw)
        local on = Pager.is_enabled()
        return Row.widget({
            width = iw,
            icon = "bluetooth_connected",
            title = _("Enable pager"),
            subtitle = _("Default on. Turning it off releases the device."),
            toggle = on,
            callback = function()
                Pager.set_enabled(not on)
                desktop:updateView()
            end,
        })
    end

    local function rescanRow(iw)
        return Row.widget({
            width = iw,
            icon = "refresh",
            title = _("Rescan now"),
            status = Pager.describe(),
            callback = function()
                Pager.rescan()
                desktop:updateView()
            end,
        })
    end

    local function lastKeyRow(iw)
        return Row.widget({
            width = iw,
            icon = "keyboard",
            title = _("Last key"),
            subtitle = Pager.last_key_text(),
            chevron = false,
        })
    end

    local function diagnosticsRow(iw)
        return Row.widget({
            width = iw,
            icon = "info",
            title = _("Pager diagnostics"),
            subtitle = _("Live key test and input-node list"),
            callback = function()
                Pager.show_diagnostics()
            end,
        })
    end

    return { {
        group = "reader",
        order = 20,
        id = "main",
        icon = "bluetooth",
        title = _("Pager"),
        page = {
            title = _("Pager"),
            sections = function()
                return {
                    { title = _("Status"), rows = { statusRow, lastKeyRow } },
                    { title = _("Settings"), rows = { toggleRow, rescanRow, diagnosticsRow } },
                }
            end,
        },
    } }
end

return {
    api = 1,
    id = "ext.kamare",
    provides = {
        source = false,
        features = { setting = { entries = settingEntries } },
    },
}
