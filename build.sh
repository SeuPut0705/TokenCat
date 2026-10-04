#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p work dist/TokenCat.app/Contents/MacOS dist/TokenCat.app/Contents/Resources
# Bundled artwork. Regenerate the v2 sources with Assets/Generator (see Assets/*-v2.md).
bundled=(runner-v2@1x.png runner-v2@2x.png runner-v2-fx@1x.png runner-v2-fx@2x.png runner-v2.json)
for head in normal blink alert sleep; do bundled+=(app-head-$head@1x.png app-head-$head@2x.png); done
for asset in $bundled app-mark-v1.png app-icon-v2-16.png app-icon-v2-32.png app-icon-v2-1024.png; do
    [[ -f "Assets/$asset" ]] || { print -u2 "이미지 누락: Assets/$asset"; exit 1; }
done
# app-mark-v1 is only the icon master; the app draws the pixel heads.
rm -f dist/TokenCat.app/Contents/Resources/runner-sheet-v1.png dist/TokenCat.app/Contents/Resources/app-mark-v1.png
for asset in $bundled; do
    cp "Assets/$asset" dist/TokenCat.app/Contents/Resources/
done
cp LICENSE dist/TokenCat.app/Contents/Resources/LICENSE
# App icon: 16/32 px from the sprite's pixel head, every larger size from the 1024 master (v2; v3 is preview only).
rm -rf work/TokenCat.iconset
mkdir -p work/TokenCat.iconset
cp Assets/app-icon-v2-16.png work/TokenCat.iconset/icon_16x16.png
cp Assets/app-icon-v2-32.png work/TokenCat.iconset/icon_16x16@2x.png
cp Assets/app-icon-v2-32.png work/TokenCat.iconset/icon_32x32.png
cp Assets/app-icon-v2-1024.png work/TokenCat.iconset/icon_512x512@2x.png
for name size in icon_32x32@2x 64 icon_128x128 128 icon_128x128@2x 256 icon_256x256 256 icon_256x256@2x 512 icon_512x512 512; do
    sips -z "$size" "$size" Assets/app-icon-v2-1024.png --out "work/TokenCat.iconset/$name.png" >/dev/null
done
iconutil -c icns work/TokenCat.iconset -o dist/TokenCat.app/Contents/Resources/TokenCat.icns
swift build --configuration release --scratch-path work/build
cp work/build/release/TokenCat dist/TokenCat.app/Contents/MacOS/TokenCat
cat > dist/TokenCat.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenCat</string>
<key>CFBundleIdentifier</key><string>dev.seuput.TokenCat</string>
<key>CFBundleName</key><string>TokenCat</string>
<key>CFBundleDisplayName</key><string>TokenCat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleIconFile</key><string>TokenCat</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 TokenCat contributors · MIT License</string>
</dict></plist>
PLIST
codesign --force --sign - dist/TokenCat.app
print "앱: $PWD/dist/TokenCat.app"
