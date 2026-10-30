#!/bin/bash
# regenerates the Chrome extension's icons with icon.swift:
#   toolbar-{light,dark}-N  the resting toolbar icon, the bare monogram in Chrome's toolbar icon colors
#   toolbar-active-N        the toolbar icon while otto fills a page in that tab, the app tile
#   tile-N                  chrome://extensions and dialogs: the app tile (96 px of art in 128, as Chrome asks)
set -euo pipefail
cd "$(dirname "$0")/.."
out=extension/icons
for n in 16 24 32; do
  swift tools/icon.swift $out/toolbar-light-$n.png $n glyph '#474747'
  swift tools/icon.swift $out/toolbar-dark-$n.png $n glyph '#C7C7C7'
  swift tools/icon.swift $out/toolbar-active-$n.png $n full
done
swift tools/icon.swift $out/tile-16.png 16 full
swift tools/icon.swift $out/tile-32.png 32 full
swift tools/icon.swift $out/tile-48.png 48 pad 6
swift tools/icon.swift $out/tile-128.png 128 pad 16
