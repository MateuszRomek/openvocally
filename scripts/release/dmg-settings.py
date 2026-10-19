# dmgbuild settings for OpenVocally.dmg. scripts/release/build-dmg.sh runs dmgbuild with this file
# and passes the app with -D app=<path>, the background with -D background=<path> and the volume
# icon with -D icon=<path>. dmgbuild writes the Finder layout into the image's .DS_Store directly,
# so the layout is the same on every build and needs no Finder or AppleScript.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides defines)
app_name = os.path.basename(app.rstrip("/"))

# APFS with LZFSE compression, the format hdiutil used before. Needs macOS 10.15 or newer to open,
# and the app needs macOS 15.
filesystem = "APFS"
format = "ULFO"

files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: dmgbuild hides an extension with SetFile, which writes Finder info onto the
# signed bundle, and codesign --verify --strict then rejects the app as "detritus". Finder already
# hides .app for apps unless the user shows all extensions.
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

# A plain icon view: no toolbar, sidebar, path bar or status bar, only the two icons.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
show_item_info = False
arrange_by = None
label_pos = "bottom"

# Finder reads the size as the whole window frame, title bar included. 432 points leave 640 by 400
# points of content under the 32-point title bar of current macOS, the area the background is drawn
# for. Icon positions are the icon centers, in points from the content's top left, and must match
# the slots dmg-background.swift draws.
window_rect = ((200, 120), (640, 432))
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (160, 168),
    "Applications": (480, 168),
}
