# Privacy

Snap Recorder is a local-only macOS screen recorder.

## What Snap Recorder accesses

- Screen Recording: required to capture a selected browser window or the main display.
- System Audio: used only when “Computer Audio” is enabled.
- Microphone: requested only after the user explicitly enables “Voice”.
- Downloads folder: used to save completed recordings automatically.
- Desktop wallpaper: read locally to create the background in browser-window mode.
- Browser application names and window titles: read only in memory to build the source picker; they are not written to disk or uploaded.

## What Snap Recorder does not do

- No account or sign-in.
- No analytics, telemetry, advertising, or crash-reporting SDK.
- No network requests or cloud upload.
- No background recording outside an active recording session.
- No collection or retention of recording content by the project maintainers.

All video and audio processing happens on the user’s Mac. Temporary files are kept in `~/Library/Application Support/SnapRecorder/Recovery/` while a recording is being finalized and are removed after a successful export. If export fails or the app is force-quit before an export choice is completed, recovery files may remain there so the recording is not silently lost; the user can remove those local files manually after confirming they are no longer needed.
