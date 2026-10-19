#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Snap Recorder.app"
BUNDLE_IDENTIFIER="io.github.shuyan-5200.SnapRecorder"
SIGNING_IDENTITY="${SNAPRECORDER_CODESIGN_IDENTITY:--}"

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

cp "$ROOT/app/SnapRecorderIcon.icns" "$APP_DIR/Contents/Resources/SnapRecorderIcon.icns"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    # A plain ad-hoc signature uses the executable CDHash as its designated
    # requirement. That hash changes after every build, so macOS TCC treats
    # each local build as a different screen-recording app. Keep the local
    # designated requirement stable; signed release builds should provide a
    # real identity through SNAPRECORDER_CODESIGN_IDENTITY.
    codesign \
        --force \
        --deep \
        --sign - \
        --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
        "$APP_DIR"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
fi

echo "$APP_DIR"
