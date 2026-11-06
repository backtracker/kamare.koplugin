local optionsutil = require("ui/data/optionsutil")
local Device = require("device")
local _ = require("gettext")
local C_ = _.pgettext

-- ConfigDialog asks IconWidget for tab icons by bare name and IconWidget only
-- looks inside KOReader's own icon dirs. A plugin-owned icon is addressed by
-- walking up to the filesystem root and back down the absolute path: "/.."
-- stays "/", so this resolves no matter which directory KOReader was launched
-- from. The icon is shipped in <plugin>/icons/.
local function plugin_icon(name)
    local source = debug.getinfo(1, "S").source
    local dir = source and source:match("^@(.+)[/\\][^/\\]+$")
    if dir and dir:sub(1, 1) == "/" then
        local icon = string.rep("../", 32) .. dir:gsub("^/+", "") .. "/icons/" .. name
        -- Verify with the same relative lookup IconWidget will do, so a
        -- launcher with an unexpected cwd gets a working icon instead of the
        -- "icon not found" fallback.
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes("resources/icons/mdlight/" .. icon .. ".svg", "mode") == "file" then
            return icon
        end
    end
    return "appbar.settings"
end

local KamareOptions = {
    prefix = "kamare",
    {
        icon = "appbar.pageview",
        options = {
            {
                name = "view_mode",
                name_text = _("View Mode"),
                toggle = {_("page"), _("continuous"), _("dual page")},
                values = {0, 1, 2},
                default_value = 0,
                event = "SetViewMode",
                args = {0, 1, 2},
                help_text = _([[- 'page' shows one page at a time- 'continuous' allows scrolling through pages- 'dual page' shows two pages side-by-side]]),
            },
            {
                name = "page_direction",
                name_text = _("Page Direction"),
                toggle = {_("LTR"), _("RTL")},
                values = {0, 1},
                default_value = 0,
                event = "SetPageDirection",
                args = {0, 1},
                help_text = _([[Set the reading direction and page-turn direction. Also selects which half is read first when Split Direction is Auto.]]),
            },
            {
                name = "wide_page_mode",
                name_text = _("Wide Page"),
                toggle = {_("Fit"), _("Split"), _("Fit Height")},
                values = {0, 1, 2},
                default_value = 0,
                event = "SetWidePageMode",
                args = {0, 1, 2},
                enabled_func = function(configurable)
                    return (configurable.view_mode or 0) ~= 2
                end,
                help_text = _([[- 'Fit' shows a wide (landscape) page scaled down to fit the screen- 'Split' cuts a wide page at the middle and shows each half full-size- 'Fit Height' zooms a wide page to fill the screen height; pan horizontally to read the rest (page view only)]]),
            },
            {
                name = "split_wide_direction",
                name_text = _("Split Direction"),
                toggle = {_("Auto"), _("LTR"), _("RTL")},
                values = {0, 1, 2},
                default_value = 0,
                event = "SetSplitWideDirection",
                args = {0, 1, 2},
                enabled_func = function(configurable)
                    return (configurable.wide_page_mode or 0) == 1
                        and (configurable.view_mode or 0) ~= 2
                end,
                help_text = _([[Reading order of the two halves of a split wide page. Auto follows Page Direction; LTR shows the left half first; RTL shows the right half first. Use LTR or RTL when a book is bound opposite to your page-turn direction.]]),
            },
            {
                name = "crop_borders",
                name_text = _("Crop Borders"),
                toggle = {_("off"), _("on")},
                values = {0, 1},
                default_value = 0,
                event = "SetCropBorders",
                args = {0, 1},
                help_text = _([[Automatically trim uniform white or black margins around page content (Mihon-style). Each page is analyzed after download; pages without uniform borders are left unchanged. Detection adds a one-time decode per page.]]),
            },
            {
                name = "page_gap_height",
                name_text = _("Page Gap"),
                buttonprogress = true,
                values = {0, 2, 4, 8, 16, 32, 64},
                default_pos = 4,
                default_value = 8,
                event = "PageGapUpdate",
                args = {0, 2, 4, 8, 16, 32, 64},
                enabled_func = function (configurable)
                    return optionsutil.enableIfEquals(configurable, "view_mode", 1)
                end,
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[In continuous view mode, sets the gap inside the viewport between stacked pages.]]),
                more_options = true,
                more_options_param = {
                    value_step = 1, value_hold_step = 10,
                    value_min = 0, value_max = 256,
                    precision = "%.1f",
                },
            },
            {
                name = "dual_page_gap",
                name_text = _("Dual Page Gap"),
                buttonprogress = true,
                values = {0, 2, 5, 8, 16, 32},
                default_pos = 3,
                default_value = 5,
                event = "DualPageGapUpdate",
                args = {0, 2, 5, 8, 16, 32},
                enabled_func = function (configurable)
                    return optionsutil.enableIfEquals(configurable, "view_mode", 2)
                end,
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[In dual page mode, sets the gap between the two side-by-side pages.]]),
                more_options = true,
                more_options_param = {
                    value_step = 1, value_hold_step = 5,
                    value_min = 0, value_max = 100,
                    precision = "%.0f",
                },
            },
            {
                name = "scroll_distance",
                name_text = _("Scroll Distance"),
                toggle = {"25%", "50%", "75%", "100%"},
                values = {25, 50, 75, 100},
                default_pos = 1,
                default_value = 25,
                event = "ScrollDistanceUpdate",
                args = {25, 50, 75, 100},
                enabled_func = function (configurable)
                    return optionsutil.enableIfEquals(configurable, "view_mode", 1)
                end,
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[In continuous view mode, sets the distance to scroll when using the up/down buttons.]]),
                more_options = true,
                more_options_param = {
                    value_step = 1, value_hold_step = 10,
                    value_min = 0, value_max = 100,
                    precision = "%.1f",
                },
            },
            {
                name = "background_color",
                name_text = _("Background Color"),
                toggle = {C_("Background color", "Black"), C_("Background color", "White")},
                values = {0, 1},
                args = {0, 1},
                default_value = 1,
                event = "SetBackgroundColor",
                help_text = _([[Choose the background color for the image viewer.]]),
            },
            {
                -- Keep the magnifier rows last in the first panel: the config
                -- dialog is bottom-anchored, so on short screens the top rows
                -- can be clipped while the last ones are always visible.
                name = "long_press_magnifier",
                name_text = _("Long-press magnifier"),
                toggle = {_("off"), _("on")},
                values = {0, 1},
                default_value = 1,
                event = "SetLongPressMagnifier",
                args = {0, 1},
                help_text = _([[Hold on a page to show a magnified window under your finger; release to return. The top 8% of the screen still opens the pager menu. Page mode only.]]),
            },
            {
                name = "magnifier_scope",
                name_text = _("Magnifier Scope"),
                buttonprogress = true,
                values = {15, 20, 25, 30, 35, 40, 50, 60},
                default_pos = 3,
                default_value = 25,
                event = "MagnifierScopeUpdate",
                args = {15, 20, 25, 30, 35, 40, 50, 60},
                labels = {"15%", "20%", "25%", "30%", "35%", "40%", "50%", "60%"},
                name_text_hold_callback = optionsutil.showValues,
                enabled_func = function(configurable)
                    return (tonumber(configurable.long_press_magnifier) or 1) == 1
                end,
                more_options = true,
                more_options_param = {
                    value_step = 5, value_hold_step = 10,
                    value_min = 10, value_max = 70,
                    precision = "%.0f",
                },
                help_text = _([[How much of the page around your finger is magnified, as a percentage of the screen's short side. The magnified window is this area times the zoom level.]]),
            },
            {
                name = "magnifier_zoom",
                name_text = _("Magnifier Zoom"),
                buttonprogress = true,
                values = {1.25, 1.5, 1.75, 2.0, 2.25, 2.5},
                default_pos = 4,
                default_value = 2.0,
                event = "MagnifierZoomUpdate",
                args = {1.25, 1.5, 1.75, 2.0, 2.25, 2.5},
                labels = {"1.25x", "1.5x", "1.75x", "2x", "2.25x", "2.5x"},
                name_text_hold_callback = optionsutil.showValues,
                enabled_func = function(configurable)
                    return (tonumber(configurable.long_press_magnifier) or 1) == 1
                end,
                more_options = true,
                more_options_param = {
                    value_step = 0.25, value_hold_step = 1,
                    value_min = 1.25, value_max = 2.5,
                    precision = "%.2f",
                },
                help_text = _([[How much the captured area is enlarged. A higher value makes the window bigger as well, so the same area is shown with bigger text.]]),
            }
        }
    },
    {
        icon = "appbar.pagefit",
        options = {
            {
                name = "zoom_mode_type",
                name_text = _("Fit"),
                toggle = {_("full"), _("width"), _("height")},
                values = {0,1,2},
                default_value = 0,
                event = "DefineZoom",
                args = {0,1,2},
                help_text = _([[Set how the page should be resized to fit the screen. In continuous mode, only 'width' is available for consistent page alignment.]]),
                enabled_func = function(configurable)
                    local mode = configurable.view_mode or 0
                    return mode == 0 or mode == 1
                end,
            },
            {
                name = "h_margin",
                name_text = _("Left/Right Margin"),
                buttonprogress = true,
                values = {0, 10, 20, 30, 40, 60, 80, 100},
                default_pos = 1,
                default_value = 0,
                event = "HMarginUpdate",
                args = {0, 10, 20, 30, 40, 60, 80, 100},
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[Sets the margin on the left and right sides of the viewport. Pages are inset from the screen edges by this amount.]]),
                more_options = true,
                more_options_param = {
                    value_step = 5, value_hold_step = 20,
                    value_min = 0, value_max = 300,
                    precision = "%.0f",
                },
            },
            {
                name = "top_margin",
                name_text = _("Top Margin"),
                buttonprogress = true,
                values = {0, 10, 20, 30, 40, 60, 80, 100},
                default_pos = 1,
                default_value = 0,
                event = "TopMarginUpdate",
                args = {0, 10, 20, 30, 40, 60, 80, 100},
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[Sets the margin at the top of the viewport.]]),
                more_options = true,
                more_options_param = {
                    value_step = 5, value_hold_step = 20,
                    value_min = 0, value_max = 300,
                    precision = "%.0f",
                },
            },
            {
                name = "bottom_margin",
                name_text = _("Bottom Margin"),
                buttonprogress = true,
                values = {0, 10, 20, 30, 40, 60, 80, 100},
                default_pos = 1,
                default_value = 0,
                event = "BottomMarginUpdate",
                args = {0, 10, 20, 30, 40, 60, 80, 100},
                name_text_hold_callback = optionsutil.showValues,
                name_text_unit = true,
                help_text = _([[Sets the margin at the bottom of the viewport.]]),
                more_options = true,
                more_options_param = {
                    value_step = 5, value_hold_step = 20,
                    value_min = 0, value_max = 300,
                    precision = "%.0f",
                },
            }
        }
    },
    {
        -- Pager (Bluetooth page-turner) settings. Previously these lived in a
        -- separate long-press menu at the top of the page; the long-press now
        -- opens this tab, so there is one place for all of them. Rows are
        -- ordered least-used first because the dialog is bottom-anchored and
        -- may clip the rows at the top on short screens.
        icon = plugin_icon("bluetooth"),
        options = {
            {
                name = "pager_rescan",
                name_text = _("Rescan now"),
                toggle = {_("Rescan")},
                values = {0},
                event = "RescanPager",
                help_text = _([[Look for the page-turner again after reconnecting it.]]),
            },
            {
                name = "pager_save_diagnostics",
                name_text = _("Save pager diagnostics to file"),
                toggle = {_("Save")},
                values = {0},
                event = "SavePagerDiagnostics",
                help_text = _([[Write the current status and recent keys to koreader/kamare-pager.log.]]),
            },
            {
                name = "pager_sniff",
                name_text = _("Sniff pager keys (30s)"),
                toggle = {_("Start")},
                values = {0},
                event = "SniffPagerKeys",
                help_text = _([[Watch every input device for 30 seconds, then open the diagnostics page.]]),
            },
            {
                name = "pager_diagnostics",
                name_text = _("Pager diagnostics"),
                toggle = {_("Open")},
                values = {0},
                event = "ShowPagerDiagnostics",
                help_text = _([[Show the live status, bound keys, and the last key received.]]),
            },
            {
                -- Keep the two real settings below the action rows, where they
                -- are always visible on short screens.
                name = "pager_swipe_inverted",
                name_text = _("Swipe Page Turn"),
                toggle = {_("Normal"), _("Inverted")},
                values = {0, 1},
                current_func = function()
                    return require("kamarepager").swipe_flipped() and 1 or 0
                end,
                event = "SetPagerSwipeInverted",
                args = {0, 1},
                help_text = _([[Invert left/right page turns when a remote's arrow keys turn pages the opposite way.]]),
            },
            {
                name = "pager_keys",
                name_text = _("Pager keys"),
                toggle = {_("Edit")},
                values = {0},
                event = "ShowPagerKeys",
                help_text = _([[Choose which buttons turn pages. Add a key by pressing it.]])
                    .. "\n" .. _([[Set up by pressing twice (next page, then previous)]]),
            },
            {
                name = "pager_enabled",
                name_text = _("Enable pager"),
                toggle = {_("off"), _("on")},
                values = {0, 1},
                current_func = function()
                    return require("kamarepager").is_enabled() and 1 or 0
                end,
                event = "SetPagerEnabled",
                args = {0, 1},
                help_text = _([[Take over the Bluetooth page-turner. Turn it off here to release the device.]]),
            }
        }
    },
    {
        icon = "appbar.settings",
        options = {
            {
                name = "prefetch_pages",
                name_text = _("Prefetch"),
                toggle = {_("Off"), _("On")},
                values = {0, 1},
                default_value = 1,
                event = "SetPrefetchPages",
                args = {0, 1},
                help_text = _([[Enable or disable automatic page prefetching. When enabled, upcoming pages are loaded in the background for smooth navigation.]]),
            },
            {
                name = "render_quality",
                name_text = _("Render Quality"),
                toggle = {_("Low"), _("High"), _("Native")},
                values = {0.8, 1.2, -1},
                default_value = -1,
                event = "SetRenderQuality",
                args = {0.8, 1.2, -1},
                help_text = _([[Controls internal rendering resolution. Low/High cap rendering based on screen size to save memory on large images. Native always uses full image resolution. Images smaller than threshold are never upscaled.]]),
            },
            {
                name = "contrast",
                name_text = _("Contrast"),
                buttonprogress = true,
                values = {0.8, 1.0, 1.5, 2.0, 4.0, 6.0, 10.0, 50.0},
                default_pos = 2,
                default_value = 1.0,
                event = "SetContrast",
                args = {0.8, 1.0, 1.5, 2.0, 4.0, 6.0, 10.0, 50.0},
                labels = {0.8, 1.0, 1.5, 2.0, 4.0, 6.0, 10.0, 50.0},
                more_options = true,
                more_options_param = {
                    value_step = 0.1, value_hold_step = 1,
                    value_min = 0.8, value_max = 50,
                    precision = "%.1f",
                },
                help_text = _([[Adjust image contrast (gamma). Higher values increase contrast for darker blacks. 1.0 is no adjustment.]]),
            },
            {
                name = "color_boost",
                name_text = _("Color Boost"),
                buttonprogress = true,
                values = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0},
                default_pos = 2,
                default_value = 1.0,
                event = "SetColorBoost",
                args = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0},
                labels = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0},
                more_options = true,
                more_options_param = {
                    value_step = 0.1, value_hold_step = 0.5,
                    value_min = 0, value_max = 6,
                    precision = "%.1f",
                },
                help_text = _([[Boost color saturation to make colors pop on dim e-ink screens. 1.0 = neutral, higher = more vivid, lower = desaturated (0 = grayscale). Uses a smart curve that protects already-vivid colors from clipping and leaves grays untouched. Only affects color rendering.]]),
            },
            {
                name = "rotation_lock",
                name_text = _("Screen Rotation"),
                toggle = {_("Auto"), _("Locked")},
                values = {false, true},
                default_value = false,
                event = "SetRotationLock",
                args = {false, true},
                help_text = _([[Auto rotation adjusts screen orientation automatically. Locked keeps the current system rotation fixed.]]),
            },
            {
                name = "footer_mode",
                name_text = _("Footer"),
                toggle = {_("Off"), _("Progress"), _("Percentage"), _("Time Left"), _("Clock")},
                values = {7, 1, 5, 6, 3},
                args = {7, 1, 5, 6, 3},
                default_value = 1,
                event = "SetFooterMode",
                help_text = _([[Choose what information to display in the footer.]]),
            },
            {
                name = "chapter_end_behavior",
                name_text = _("Chapter End"),
                toggle = {_("Stop"), _("Ask"), _("Auto")},
                values = {0, 1, 2},
                default_value = 1,
                event = "SetChapterEndBehavior",
                args = {0, 1, 2},
                help_text = _([[Choose what happens when you reach the end of a chapter: 'Stop' stays on the last page, 'Ask' shows a dialog to continue or close, 'Auto' automatically continues to the next chapter.]]),
            },
            {
                name = "frontlight",
                name_text = _("Frontlight"),
                toggle = { _("Adjust") },
                values = { 0 },
                event = "ShowFrontlight",
                help_text = _([[Open the frontlight controls to adjust brightness and warmth.]]),
                enabled_func = function() return Device:hasFrontlight() end,
            }
        }
    },
    -- Lets the viewer jump straight to the pager tab (top-8% long-press).
    pager_panel = 3,
}

return KamareOptions
