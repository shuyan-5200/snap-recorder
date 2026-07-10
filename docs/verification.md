# Verification

This document records reproducible project-level checks without retaining user recordings, window titles, personal paths, or private media.

## Automated self-test

Run:

```bash
swift build -c release
.build/release/SnapRecorder --self-test
```

The self-test uses generated frames and tones. It does not request screen or microphone permission and does not read user content.

Current coverage:

- Browser layout preserves source aspect ratio and native pixels up to the 3840×2160 cap.
- Full-screen sizing preserves display aspect ratio and does not upscale smaller sources.
- Browser content occupies at least 94% of the output width and height with integer-aligned placement.
- H.264 High Profile encoding and MP4 finalization complete successfully.
- Paused time is removed from the final media timeline.
- Synthetic computer audio and microphone audio are encoded as independent tracks.
- Voice-only combined export is covered with computer audio disabled.
- Combined export produces one mixed AAC track and keeps the H.264 video samples byte-identical.
- Separate voice export writes an exact valid PCM frame count for the video timeline and stays within the 40 ms cross-tool tolerance.

## v0.2.0 manual validation

The release candidate was exercised on a supported recent macOS version with temporary real captures that were deleted immediately after inspection:

- Full-screen capture exported H.264 High Profile at the display's native resolution; Snap Recorder's window and recording controls were absent from the media.
- Browser-only capture completed without maximizing the browser, preserved the selected window's native aspect ratio and pixels, and showed only the intended wallpaper margin.
- Microphone-off recording stopped directly into one MP4 with no export choice.
- Microphone-on recording allowed both export cards to remain selected and produced the combined MP4, separate MP4, and M4A in one action, without a ZIP.
- The compressed H.264 video stream was byte-identical in the combined and separate MP4 files, confirming that adding voice did not re-encode the picture.
- The standalone voice file was AAC-LC, mono, 48 kHz, 192 kbps, and contained exactly the same valid media duration as the matching video in the native macOS media timeline.
- AAC priming and remainder metadata were inspected. Some packet-level tools include encoder padding in their nominal duration display; decoded media remained inside the 40 ms interoperability tolerance.

## Manual release checklist

- Browser window: start, pause, resume, stop, and confirm no unrelated app or Snap Recorder UI appears.
- Full screen: start, pause, resume, stop, and confirm Snap Recorder is excluded.
- Microphone off: stopping automatically saves exactly one MP4.
- Microphone on + computer audio on: verify both combined and separate export.
- Microphone on + computer audio off: verify combined voice-only video and separate silent-video + M4A output.
- Confirm separate export creates exactly two files and no ZIP.
- Select both export cards and confirm one action creates the combined MP4, separate MP4, and M4A with one shared timestamp/suffix.
- Confirm final MP4 dimensions match the source policy and play in QuickTime.
- Confirm the standalone M4A and MP4 effective playback timelines differ by no more than 40 ms.
- Deny microphone permission once and confirm recording does not start until permission is restored.
- Inspect the built App and release archive for personal names, email addresses, local paths, recordings, logs, and build caches.

## Release build checks

```bash
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "build/Snap Recorder.app"
du -sh "build/Snap Recorder.app"
```
