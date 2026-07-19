#!/bin/bash
# Render AppIcon.svg into AppIcon.icns (each size rasterised directly from the
# SVG for crispness). Requires rsvg-convert (brew install librsvg).
set -e
cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)"; exit 1; }

SET="AppIcon.iconset"
rm -rf "$SET"; mkdir "$SET"
render() { rsvg-convert -w "$1" -h "$1" AppIcon.svg -o "$SET/$2"; }

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "wrote AppIcon.icns"
