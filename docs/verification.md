# Verification

This document records reproducible project-level checks without retaining user recordings, window titles, personal paths, or private media.

## v0.4.0 build 11: discrete portrait presets and window dragging

Published release update. The reported continuous-slider gesture could move the entire window because the main window allowed background dragging. The shared main-window factory now disables background dragging while retaining native title-bar movement.

The continuous slider is removed from the product. Portrait correction now offers Original / Natural / Soft, defaulting to Original. Natural and Soft use different edge-preserving noise-reduction thresholds and 60% / 85% processed-image blends over a wider inner-cheek mask; protected features and background remain excluded. An already smooth or motion-blurred face can still show only a subtle difference. No face warp, makeup, paid library, or network dependency was added.

Verification:

- Release build and the complete self-test passed with all three preset states. Synthetic noisy-cheek tests require Natural to reduce variance by at least 15%, and Soft to reduce it by a further 10%; both preserve the artificial eye/mouth edges exactly. Original and no-face paths preserve the image.
- A camera-free AppKit test window used the production window factory and production settings view. The three presets were visible, and a separate test-only legacy slider responded to pointer track clicks while the window origin remained unchanged. Automated drag commands did not reliably exercise native dragging, including title-bar movement; do not count those as completed physical-gesture tests. The test slider is not included in the installed product.
- The same previously recorded local face frame was processed as Original, Natural, and Soft for side-by-side inspection. Changes stayed limited to cheeks; on this already soft sample, visible differences remained restrained. Pixel-level differences are not a guarantee of dramatic perceptual change.
- No new live-camera recording was used to claim a complete build 11 hardware pass. The camera/encoding architecture is unchanged; the historical build 10 recording below is separate evidence, not a new test result.
- The installed build 11 Universal App passed strict signature verification and the complete self-test. Its real settings UI selected Soft, Natural, and Original successfully, switched the camera overlay from bottom-right to top-left and back, and closed with Escape. The camera was turned off afterward and the main window left open. Temporary comparison media and the isolated test app were moved to macOS Trash; the source recording was left unchanged.
- Public-release leakage checks confirmed that the v0.4.0 merge added no image, video, ZIP, DMG, or App files to the repository. The tracked media files are only the pre-existing product UI screenshots. The release ZIP contains the App bundle, executable, icon, Info.plist, and code-signature metadata; it contains no screenshots, recordings, or portrait test media. Local release asset SHA-256: `bd3f8cc9889708e52f932fb13c502bfbc1a74883d2360e9bf77e670ea7eb2d49`.

## v0.4.0 build 10: native portrait correction and position controls

This is a local-only evaluation build, not a published GitHub release. The source and single installed App entry point are updated together; historical GitHub releases remain unchanged.

Completed checks:

- Release build, full `--self-test`, Universal 2 packaging (arm64 + x86_64), and strict code-signature verification passed. The self-test includes the native portrait filter and does not access a real camera.
- Synthetic image tests verify disabled/zero-strength identity, safe intensity bounds, reduced low-amplitude cheek noise at the default 0.35 strength, byte-identical protected eye/mouth/background pixels, incomplete-face fallback, detector throttling, face-loss clearing, reset, and invalid/backward timestamps.
- Installed UI tests selected all four corners in browser mode and again in region mode. Selection changed from bottom-right to top-left successfully; natural correction toggled on, and the strength changed from 0.35 to 0.45 and back. The explicit Done action closed the in-window settings card. The final installed build also passed an Escape-to-close check; after verification the camera was turned off and the clean main window left open.
- A previously recorded local face sample exercised the real Vision detector and production correction pipeline. Image comparison showed a subtle cheek change without facial geometry changes. The sample was not added to the repository or uploaded.
- A separate 1280 × 720 benchmark made from that local sample ran 120 frames including rendering. On this Mac, the first frame took about 184 ms; subsequent median / 95th-percentile / maximum times were about 3.7 / 16.8 / 24.6 ms. A smaller cold run initially took about 764 ms. These are sample-processing measurements, not a guarantee across cameras or Macs; processing is off the main UI thread.
- With correction enabled at 0.35 and the overlay set to top-left, a real browser-window/camera recording exported one H.264 MP4: 2866 × 1898, 56.635 seconds, 1,699 frames at 30 fps, 48,043,575 bytes. Microphone and computer audio were off. Decoded inspection showed a single correctly positioned rounded overlay, and five consecutive camera-area checksums differed. The camera showed the room, so this checks live capture/export and no-face fallback, not a live-person beauty comparison.
- Recording ended through the app's quit-protection End and Save action, followed by highest-quality export. The camera stopped and its preview disappeared before the quality-choice screen.

Boundaries and remaining manual checks:

- The camera/recorder windows deliberately exclude themselves from screen sharing; automated screenshots of the settings window were blank. UI selection states were verified through accessibility, not a visual screenshot audit or exhaustive physical click-position test.
- Automation did not reliably target the recording HUD or deliver its global Escape shortcut. Actual HUD stop, pause/resume, and keyboard interaction remain manual checks. The settings close button has an explicit Escape shortcut, in addition to its clickable close/Done actions.
- A newly created blank browser window did not deliver screen frames and correctly produced the existing actionable failure state; selecting an already rendered browser window completed recording. Do not use an unrendered/hidden helper window as the real-capture benchmark.
- Please evaluate naturalness during speech, head movement, glasses, side lighting, and partial occlusion. Full-screen/region camera exports and real microphone combinations retain the earlier manual acceptance items below.

## v0.4.0 build 9 historical preview status

Camera support is implemented in v0.4.0 build 9, based on the merged v0.3.1 recorder. This local preview build is installed for evaluation and has not been published as a GitHub release. The completed checks and remaining hardware acceptance items are listed separately below.

The v0.3.1 installation was accepted by the user before camera work began. Earlier local App archives were removed from active project/download locations using recoverable macOS Trash; historical GitHub releases were not changed. The installed App continues to use the single `/Applications/Snap Recorder.app` entry point.

Completed local verification:

- The installed v0.4.0 build 9 App is Universal 2, containing arm64 and x86_64 executables; code-signature verification passed. The installed executable's complete `--self-test` run passed, including camera frame-cache tests.
- A real browser-window recording with the camera enabled completed highest-quality export to one H.264 MP4: 2866 × 1898 pixels, 176.588 seconds, 5,295 video frames, approximately 30 fps. Computer audio and microphone were both disabled.
- Decoded frame inspection showed exactly one default rounded-square camera picture in the lower-right corner, with correct aspect-fill proportions. The floating preview was not duplicated in the inspected frame.
- A second real browser/camera recording used a small circular overlay in the upper-left corner and completed compact export: H.264, 2866 × 1898 pixels, 58.166667 seconds, 1,743 video frames, and 12,243,091 bytes. Decoded frame inspection confirmed one camera picture with the selected position, shape, and size. This was a different recording from the highest-quality test, so the two file sizes are not a controlled compression-ratio comparison.
- With the browser page static, pixel comparisons in the camera area differed across multiple seconds, confirming that the camera picture continued updating.
- Both real recordings were stopped through the app's quit-protection “End and Save” action, which entered the existing quality-choice flow. The camera was released and its preview disappeared before export selection. The recording HUD's stop button was not exercised by this UI test.
- The final preview/HUD layering change uses the same window level and brings the HUD to the front afterward; the final source build and installed App self-test passed. Direct HUD-button interaction remains a manual acceptance item.
- Test camera footage and recordings are not included in the repository; this record omits media filenames, source window titles, and personal media paths.

Pending camera hardware acceptance:

- Full-screen and region recordings: confirm the final video includes exactly one camera overlay and excludes all preview/recording UI.
- Complete the remaining shape, size, corner-position, and mirror on/off combinations against exported MP4 files; the synthetic 48-combination checks below already pass.
- Test portrait and landscape regions and confirm the camera remains inside the output frame without stretching the person.
- The automation could not select the recording HUD reliably, so its stop button and real-camera pause/resume were not exercised. Verify those controls, synchronization with a visible screen/camera action, and the absence of frozen lead-in, duplicated pause intervals, or audio drift; only the synthetic pause/timeline checks below have passed.
- Camera on with real microphone and/or computer audio: confirm combined and separate-voice exports retain the overlay and sound stays aligned. Highest-quality video passthrough is covered by synthetic tests, not this silent hardware recording.
- Confirm release after switch-off, idle main-window close, and app exit. Reopening must not leave a stale preview or unrecoverable busy device; release after stopping was verified above.
- Deny camera permission, try no connected camera / an unavailable camera, and disconnect a camera during recording. Verify actionable feedback and best-effort finalization of already-recorded content.

## Automated self-test

Run:

```bash
swift build -c release
.build/release/SnapRecorder --self-test
```

The self-test uses generated frames and tones. It does not request screen, microphone, or camera permission and does not read user content. The release-configuration build and complete self-test passed, including a run from the installed v0.4.0 build 11 App. Generated camera frames verify rendering and media output; they cannot replace the remaining hardware checklist above.

Current coverage:

- Browser layout preserves source aspect ratio and native pixels up to the 3840×2160 cap, with capture and output dimensions identical.
- Full-screen sizing preserves display aspect ratio and does not upscale smaller sources.
- Browser content fills the full output canvas without synthetic desktop margins.
- Stopping preserves a highest-quality pending source and requires a post-record quality choice.
- Highest-quality export keeps compressed video samples byte-identical; compact export re-encodes at the same dimensions with a one-third target bitrate.
- H.264 High Profile encoding and MP4 finalization complete successfully.
- Paused time is removed from the final media timeline.
- Synthetic computer audio and microphone audio are encoded as independent tracks.
- Voice-only combined export is covered with computer audio disabled.
- Combined export produces one mixed AAC track and keeps the H.264 video samples byte-identical.
- Separate voice export writes an exact valid PCM frame count for the video timeline and stays within the 40 ms cross-tool tolerance.
- Camera frame-cache tests select the newest eligible frame at or before the screen timestamp, reject future/invalid/stale frames, ignore out-of-order delivery, limit retained source buffers to three, and clear all frames on reset.
- Camera layout and masks cover 48 combinations: landscape/portrait canvases × four corners × three sizes × rounded-square/circular shapes. Pixel checks confirm placement, proportional size, transparent corners, and unchanged screen content outside the overlay.
- Camera shadow and thin border render around the overlay without replacing its interior picture.
- Mirroring and centered aspect-fill cropping preserve the expected left/right camera image. The camera remains in full color above the region focus mask; a missing camera frame adds no placeholder overlay.
- A static synthetic screen with changing camera frames is encoded to a real temporary MP4, then decoded to verify that the camera picture changes, accepted frame counts match, and video timestamps strictly increase.
- Camera frames are rejected while paused. The resumed MP4 contains the new camera image and excludes the paused interval from its playback duration.

## Previous v0.2.0 manual validation

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
- Confirm the browser fills the complete frame with no wallpaper, rounded mask, shadow, or added margin.
- Record a changing scene, export highest quality, repeat and export compact; confirm dimensions match and compare file size and text clarity.
- Full screen: start, pause, resume, stop, and confirm Snap Recorder is excluded.
- Microphone off: stopping shows both quality choices and the selected option exports exactly one MP4.
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
