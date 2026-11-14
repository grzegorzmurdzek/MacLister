#!/bin/bash
# Builds MacLister.app (agent app, LSUIElement) into ./build
#   ./build.sh                    release build for this Mac's architecture
#   ./build.sh debug              debug build
#   ./build.sh release --universal   arm64 + x86_64 in one app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ARCH_FLAGS=()
if [ "${2:-}" = "--universal" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# ${ARCH_FLAGS[@]+...}: an empty array must not trip `set -u` in macOS's bash 3.2
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacLister"

APP="build/MacLister.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacLister"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Interface languages: English is built in (the text is the key), Polish comes from pl.lproj.
for lproj in Support/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done

# Ad-hoc signature. The requirement pins the identifier instead of the per-build cdhash, so
# Accessibility / Input Monitoring grants survive rebuilds.
codesign --force --sign - --identifier com.example.MacLister \
    -r='designated => identifier "com.example.MacLister"' "$APP"

echo "Built: $PWD/$APP"
echo "Run:   open \"$PWD/$APP\""
