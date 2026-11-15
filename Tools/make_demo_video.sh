#!/bin/bash
# Records the website video: the app plays scripted scenes with made-up files, Tools/demo_video_edit.py cuts them.
#   Tools/make_demo_video.sh                 Polish and English, light
#   LANGS=pl Tools/make_demo_video.sh        one language
# Needs macOS 15+ and Screen Recording access for the app that runs the script. Results: build/demo-video/.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh release >/dev/null
APP="build/MacLister.app/Contents/MacOS/MacLister"
OUT="$PWD/build/demo-video"
mkdir -p "$OUT"
for lang in ${LANGS:-pl en}; do
    "$APP" --demo-video "$OUT/raw-$lang.mov" -AppleLanguages "($lang)" -visibleColumns "(size,date)" \
        -centerOnCursor NO -desktopTrigger doubleClick -showFolderTree NO | grep -E "^(recording|wrote|demo video|recording failed)"
    python3 Tools/demo_video_edit.py "$OUT/raw-$lang.mov" "$OUT/maclister-demo-$lang.mp4"
done
