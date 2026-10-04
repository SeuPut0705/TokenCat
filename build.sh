#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p work dist/TokenCat.app/Contents/MacOS dist/TokenCat.app/Contents/Resources
for asset in app-mark-v1 runner-sheet-v1; do
    [[ -f "Assets/$asset.png" ]] || { print -u2 "이미지 누락: Assets/$asset.png"; exit 1; }
    cp "Assets/$asset.png" dist/TokenCat.app/Contents/Resources/
done
cp LICENSE dist/TokenCat.app/Contents/Resources/LICENSE
mkdir -p work/TokenCat.iconset
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/app-mark-v1.png --out "work/TokenCat.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/app-mark-v1.png --out "work/TokenCat.iconset/icon_${size}x${size}@2x.png" >/dev/null
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
<key>CFBundleShortVersionString</key><string>0.6.1</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>TokenCat</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - dist/TokenCat.app
print "앱: $PWD/dist/TokenCat.app"
