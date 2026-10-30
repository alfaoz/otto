# dmgbuild settings for otto's DMG: the app on the left, Applications on the right, on the background
# tools/dmg-background.swift draws. release.sh passes app and background with -D.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
files = [app]
symlinks = {"Applications": "/Applications"}
format = "ULFO"  # lzfse: smaller than zlib, opens on every macOS otto runs on
filesystem = "APFS"
background = defines["background"]  # noqa: F821
# 400 pt of background under a title bar of about 32
window_rect = ((200, 160), (660, 432))
default_view = "icon-view"
show_icon_preview = False
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {os.path.basename(app): (190, 196), "Applications": (470, 196)}
# no hide_extensions: it sets a Finder flag on the app, and the flag fails a strict signature check
