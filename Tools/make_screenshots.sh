#!/bin/bash
# Draws the README / forum pictures with made-up files (English into docs/screenshots).
#   Tools/make_screenshots.sh            English only
#   LANGS="en pl" Tools/make_screenshots.sh   Polish pictures go to docs/screenshots/pl too
# Needs Screen Recording access for the app that runs the script. Only MacLister's own windows end up in the
# pictures: a window of the app covers the screen behind them. The invented files live in
# /Users/Shared/MacLister Demo while the pictures are made and are removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh release >/dev/null
APP="build/MacLister.app/Contents/MacOS/MacLister"
COLUMNS_ARG="(size,date,kind)"        # a command-line default: nothing is written to the user's settings
for lang in ${LANGS:-en}; do
    out="docs/screenshots"; [ "$lang" = pl ] && out="docs/screenshots/pl"
    for mode in light dark; do
        extra=(); [ "$mode" = dark ] && extra=(dark)
        "$APP" --screenshots "$out" ${extra[@]+"${extra[@]}"} -AppleLanguages "($lang)" -visibleColumns "$COLUMNS_ARG" -terminalBundleID com.apple.Terminal -listerTabs YES -centerOnCursor NO -desktopTrigger doubleClick -showFolderTree NO | grep -E "^(wrote|nothing|capture)"
    done
done

# PNGs of this size are ~2 MB each; high-quality JPEGs are a tenth of that and look the same for screenshots.
find docs/screenshots -name '*.png' -print0 | while IFS= read -r -d '' png; do
    sips -s format jpeg -s formatOptions 90 "$png" --out "${png%.png}.jpg" >/dev/null && rm "$png"
done
