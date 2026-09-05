# Privacy

Snap Recorder is a local-only macOS screen recorder.

## What Snap Recorder accesses

- Screen Recording: required to capture a selected browser window or the main display.
- System Audio: used only when “Computer Audio” is enabled.
- Microphone: requested only after the user explicitly enables “Voice”.
- Camera: requested only after the user explicitly enables “Camera”. Camera and microphone switches are independent; enabling the camera does not enable the microphone. The selected device's video is shown in a local preview and composited directly into the screen recording.
- Optional Natural Retouch: off by default. When enabled, Apple's Vision framework detects face regions in camera frames in memory, and Core Image applies gentle skin smoothing to those regions. This is face-region detection, not recognition of a person's identity. It does not reshape faces, apply makeup, or process the recorded desktop. The preview and recording use the same processed camera pixels.
- Downloads folder: used to save completed recordings automatically.
- Browser application names and window titles: read only in memory to build the source picker; they are not written to disk or uploaded.

## What Snap Recorder does not do

- No account or sign-in.
- No analytics, telemetry, advertising, or crash-reporting SDK.
- No network requests or cloud upload.
- No screen or audio recording outside an active recording session. When explicitly enabled, the camera may provide a live local preview before recording; those preview-only frames are not saved. Camera access ends when the switch is turned off, recording stops, or the idle main window closes.
- No facial identity recognition or generation or storage of face embeddings, identity profiles, or user-specific face models. Face-region detection is performed only while Natural Retouch is enabled; its transient results are used in memory and are not saved or uploaded. Turning Natural Retouch off stops this detection and processing. The camera image itself, including any enabled retouching, remains visible in the saved recording.
- No collection or retention of recording content by the project maintainers.

All video and audio processing happens on the user’s Mac. Camera video is included in the final screen recording, not uploaded or exported as a separate camera file. The local preview window itself is excluded from screen sharing to avoid recording it twice. Temporary files are kept in `~/Library/Application Support/SnapRecorder/Recovery/` while a recording is being finalized and are removed after a successful export. If export fails, a camera disconnect interrupts recording, or the app is force-quit before an export choice is completed, recovery files may remain there so the recording is not silently lost; the user can remove those local files manually after confirming they are no longer needed.
