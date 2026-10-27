local Utils = require("kamareutils")
local CacheUtil = require("kamarecacheutil")
local T = require("ffi/util").template
local _ = require("gettext")

return function(t)
    -- Kavita's loose/volume chapters use -100000 as a sentinel number; it must
    -- not appear in titles ("第 -100000 章: CLAYMORE (17)").
    t.eq(Utils.buildChapterTitle({ number = -100000, titleName = "CLAYMORE (17)" }),
        "CLAYMORE (17)", "sentinel chapter number dropped")
    t.eq(Utils.buildChapterTitle({ number = 5, titleName = "Day Off" }),
        T(_("Ch. %1"), 5) .. ": Day Off", "real chapter number kept")
    t.eq(Utils.buildChapterTitle({ number = 12, titleName = "Ch. 12" }),
        "Ch. 12", "title already names the chapter")

    -- Kavita returns localized volume names like "17 卷"; do not render
    -- "Volume 17: 17 卷".
    t.eq(Utils.buildVolumeTitle({ number = 17, name = "17 卷" }),
        T(_("Volume %1"), 17), "localized volume name normalized")
    t.eq(Utils.buildVolumeTitle({ number = 17, name = "Volume 17" }),
        "Volume 17", "english volume name kept")
    t.eq(Utils.buildVolumeTitle({ number = 3, name = "Beginning" }),
        T(_("Volume %1"), 3) .. ": Beginning", "named volume prefixed")
    t.eq(Utils.buildVolumeTitle({ number = 4 }),
        T(_("Volume %1"), 4), "volume without name")

    t.ok(CacheUtil.natural_compare("CLAYMORE (2)", "CLAYMORE (10)"),
        "natural compare numbers")
    t.ok(not CacheUtil.natural_compare("CLAYMORE (10)", "CLAYMORE (2)"),
        "natural compare reversed")
end
