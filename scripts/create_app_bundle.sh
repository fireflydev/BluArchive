#!/usr/bin/env bash
set -euo pipefail

# Build universal release binary
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! swift build -c release --arch arm64 2>/dev/null; then
  echo "Run from Terminal (not sandboxed): swift build -c release --arch arm64"
  exit 1
fi

if ! swift build -c release --arch x86_64 2>/dev/null; then
  echo "Run from Terminal (not sandboxed): swift build -c release --arch x86_64"
  exit 1
fi

BIN_ARM64="$ROOT/.build/arm64-apple-macosx/release/BDXLBackupApp"
BIN_X64="$ROOT/.build/x86_64-apple-macosx/release/BDXLBackupApp"
if [[ ! -f "$BIN_ARM64" || ! -f "$BIN_X64" ]]; then
  echo "Could not find both binaries under .build/<arch>-apple-macosx/release/BDXLBackupApp"
  exit 1
fi

APP_NAME="BluArchive"
OUT_DIR="$ROOT/build"
BUNDLE="$OUT_DIR/${APP_NAME}.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

lipo -create "$BIN_ARM64" "$BIN_X64" -output "$BUNDLE/Contents/MacOS/BDXLBackupApp"
chmod +x "$BUNDLE/Contents/MacOS/BDXLBackupApp"
mkdir -p "$BUNDLE/Contents/Resources"

ICON_SRC="$ROOT/assets/BluArchiveIcon-1024.png"
ICON_FILE_NAME="AppIcon"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$OUT_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"

  sips -z 16 16 "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

  if iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"; then
    ICON_FILE_NAME="AppIcon"
  else
    echo "iconutil failed; using PNG icon fallback."
    cp "$ICON_SRC" "$BUNDLE/Contents/Resources/AppIcon.png"
    ICON_FILE_NAME="AppIcon.png"
  fi
fi

PLIST="$BUNDLE/Contents/Info.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>BDXLBackupApp</string>
  <key>CFBundleIdentifier</key>
  <string>local.bdxl.BDXLBackupApp</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_FILE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.3</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>BluArchive helper — uses tar, par2, shasum, hdiutil.</string>
</dict>
</plist>
EOF

echo "Created: $BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/BDXLBackupApp"
