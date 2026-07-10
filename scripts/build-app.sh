#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Snap Recorder.app"
ICONSET_DIR="$ROOT/.build/SnapRecorderIcon.iconset"
MASTER_ICON="$ROOT/.build/SnapRecorderIcon-1024.png"

swift build --package-path "$ROOT" -c release --arch arm64
swift build --package-path "$ROOT" -c release --arch x86_64

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
lipo -create \
    "$ROOT/.build/arm64-apple-macosx/release/SnapRecorder" \
    "$ROOT/.build/x86_64-apple-macosx/release/SnapRecorder" \
    -output "$APP_DIR/Contents/MacOS/SnapRecorder"
strip -S -x "$APP_DIR/Contents/MacOS/SnapRecorder"
cp "$ROOT/app/Info.plist" "$APP_DIR/Contents/Info.plist"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
qlmanage -t -s 1024 -o "$ROOT/.build" "$ROOT/assets/SnapRecorderIcon.svg" >/dev/null 2>&1
mv "$ROOT/.build/SnapRecorderIcon.svg.png" "$MASTER_ICON"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$MASTER_ICON" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$MASTER_ICON" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/SnapRecorderIcon.icns"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
