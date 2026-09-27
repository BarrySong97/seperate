# @purpose dmgbuild settings for the Seperate DMG: one installer icon on the designed background.
# @role    Loaded by package-dmg.sh via `dmgbuild -s` with -D installer=… -D background=….
# @deps    dmgbuild (injects `defines`), installer app and background TIFF from package-dmg.sh.
# @gotcha  Not a runnable script (`defines` is injected); icon_locations must match make-installer-assets.swift; see docs/modules/release/README.md
# dmgbuild settings for the Seperate DMG: one installer icon on the designed background.
# Used by scripts/package-dmg.sh (dmgbuild -s scripts/dmg-settings.py -D installer=… -D background=…).
import os.path

installer = defines["installer"]
name = os.path.basename(installer)

format = "UDZO"
filesystem = "HFS+"
files = [installer]
hide_extension = [name]

background = defines["background"]
window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
# Centers of icons in window points; matches the layout drawn by scripts/make-installer-assets.swift.
icon_locations = {name: (300, 190)}
