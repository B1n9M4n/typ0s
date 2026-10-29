#!/bin/bash
# Builds typ0s.app (Apple Silicon + Intel) and a shareable zip into ./build
# Needs Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

SOURCES=(Typ0sApp.swift Typ0sUI.swift FastTypoEngine.swift WordModel.swift FixGate.swift RankModel.swift HarperGrammar.swift)
VERSION="0.4.0"
MIN_MACOS="14.0"
OUT="build"
APP="$OUT/typ0s.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling (arm64 + x86_64)…"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" "${SOURCES[@]}" -o "$OUT/typ0s-$arch" 2>/dev/null
done
lipo -create "$OUT/typ0s-arm64" "$OUT/typ0s-x86_64" -o "$APP/Contents/MacOS/typ0s"
rm "$OUT/typ0s-arm64" "$OUT/typ0s-x86_64"

echo "→ Adding the word lists…"
mkdir -p "$APP/Contents/Resources/Dictionary"
cp Dictionary/words.txt Dictionary/bigrams.txt Dictionary/LICENSE.md "$APP/Contents/Resources/Dictionary/"

# Harper grammar checker (Apache-2.0), if installed with `brew install harper`; it's Apple Silicon only
HARPER="$(command -v harper-cli || true)"
if [ -n "$HARPER" ]; then
  echo "→ Adding the Harper grammar checker…"
  HARPER="$(realpath "$HARPER")"
  mkdir -p "$APP/Contents/Helpers"
  cp "$HARPER" "$APP/Contents/Helpers/harper-cli"
  chmod u+w "$APP/Contents/Helpers/harper-cli"
  HARPER_LICENSE="$(dirname "$HARPER")/../LICENSE"
  if [ -f "$HARPER_LICENSE" ]; then cp "$HARPER_LICENSE" "$APP/Contents/Resources/Harper-LICENSE"
  else echo "  warning: Harper's LICENSE not found next to $HARPER; add it to the app by hand before sharing"; fi
fi

echo "→ Drawing the app icon…"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/typ0s" --export-icon "$OUT/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$OUT/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$OUT/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$OUT/icon-1024.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>typ0s</string>
    <key>CFBundleDisplayName</key><string>typ0s</string>
    <key>CFBundleIdentifier</key><string>io.github.b1n9m4n.typ0s</string>
    <key>CFBundleExecutable</key><string>typ0s</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable local certificate if you have one, so macOS keeps the Accessibility
# permission across rebuilds. Without it, sign ad-hoc (works, but re-allow after each rebuild).
SIGN_ID="typ0s Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo "→ Signing with \"$SIGN_ID\"…"
else
  echo "→ Signing (ad-hoc)…"
  SIGN_ID="-"
fi
# The bundled helper is signed ad-hoc; the app around it gets the stable identity
if [ -f "$APP/Contents/Helpers/harper-cli" ]; then codesign --force --sign - "$APP/Contents/Helpers/harper-cli"; fi
codesign --force --sign "$SIGN_ID" "$APP"

echo "→ Zipping for sharing…"
ditto -c -k --norsrc --keepParent "$APP" "$OUT/typ0s-$VERSION.zip"

echo "✓ Done: $APP  and  $OUT/typ0s-$VERSION.zip"
