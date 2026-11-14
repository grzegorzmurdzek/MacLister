#!/bin/bash
# Builds a universal MacLister.app and zips it for a GitHub release: dist/MacLister-<version>-macos.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
./build.sh release --universal

ZIP="MacLister-$VERSION-macos.zip"
mkdir -p dist
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --keepParent build/MacLister.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")

echo "Package: $PWD/dist/$ZIP"
cat "dist/$ZIP.sha256"
