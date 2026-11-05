--[[--
Feature manifest for Moon's Kavita cache page.

Moon only reads and renders these strings; it does not interpret them.
Keep this list to user-visible features shown in Moon's cache page, in display
order. The file is optional: older builds do not ship it and Moon hides the
feature row. Text goes through the plugin's own gettext catalog.

@module kamarefeatures
--]]

local _ = require("gettext")

return {
    api_version = 1,
    features = {
        _("Cache (offline reading and cleanup)"),
        _("Dual-page split"),
        _("Crop borders"),
        _("Long-press magnifier"),
        _("Bluetooth page turner"),
    },
}
