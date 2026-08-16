local _ = require("gettext")

return {
    name = "lanfetch",
    fullname = _("LAN PDF Downloader"),
    description = _([[Download PDFs served on the local network (LAN) by bare IP and port with an e-ink optimized keypad, subnet autodetection, hierarchical folder presets, and ephemeral URL state.]]),
    category = "network",
    version = "1.0",
}
