"""Finder layout for the Mousü disk image. Loaded by dmgbuild."""

from pathlib import Path
import subprocess
import unicodedata

app = Path(defines["app"])
format = "UDZO"
filesystem = "HFS+"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/Mousu.icns")
background = defines["background"]
window_rect = ((160, 160), (720, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
show_icon_preview = False
arrange_by = None
grid_spacing = 64
scroll_position = (0, 0)
icon_size = 128
text_size = 14
label_pos = "bottom"
# HFS+ uses decomposed filenames; Finder requires the same spelling in its layout.
icon_locations = {unicodedata.normalize("NFD", app.name): (190, 230), "Applications": (530, 230)}


# Finder extension flags add forbidden metadata to an otherwise signed bundle.
# Verify the copy after dmgbuild finishes applying its layout and attributes.
def create_hook(volume, options):
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(Path(volume) / app.name)],
        check=True,
    )
