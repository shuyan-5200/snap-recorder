# Verification

This document records reproducible project-level checks without retaining user recordings, window titles, personal paths, or private media.

## 2026-10-09: portrait protection quantization fix

- The portrait production processor is unchanged. Only active-filter protection checks now tolerate at most one 8-bit level per RGB channel; alpha is still exact. Original/off/no-face bypass and detection-lifecycle identity comparisons remain byte-identical.
- Both Natural and Soft must preserve every sampled background edge's location and contrast. An all-black mask must preserve the complete fixture within the same RGB tolerance, with exact alpha.
- Positive controls cover identical images, one-level channel changes and opposing one-level changes on the two sides of an edge. Negative controls require rejection of a two-level color change, a one-level alpha change, an actual 2px-radius Gaussian blur and a one-pixel edge shift. Cheek coverage, meaningful noise reduction, feature protection and face-loss recovery checks remain active.
- `swift build -c release` passed. The complete `--self-test` passed twice, including on the final source: generated video/pause timing, repeat export/session cleanup, all four relative size tiers, custom ceiling, naming, mixed/separate/audio-only exports, voice alignment within 40ms, camera overlay/static-screen motion and the complete portrait diagnostic group.
- Final generated export measurements: 1920×1080 / 1440×810 / 960×540 / 480×270 at 30 fps, with 4,246,901 / 4,090,953 / 1,759,296 / 674,159 bytes. The 0.75 MB custom ceiling retried to 679,641 bytes. No screen, microphone or camera hardware was captured during these tests.
- `scripts/build-app.sh` rebuilt both architectures successfully. The resulting Universal App reports `x86_64 arm64`, passes strict deep signature verification and Info.plist lint, and its bundled executable passed the complete `--self-test` as well. The installed application was not replaced and no binary release was published.
- This fixes the local false positive recorded below; the earlier preflight failure describes commit `697b995`, not the repaired source. Native slider-drag and extended physical-device acceptance limits below are unchanged.

## 2026-10-09: upstream PR preflight (before portrait fix, commit 697b995)

- Target: `shuyan-5200/snap-recorder:main`, verified at `d523be7`; source branch: `codex/quit-and-relative-video-size`. Previous upstream PRs #14 and #15 are merged. Version metadata remains 1.5.0/build 20; this is a development PR, not a new binary release.
- `swift build -c release` passed. `--self-test --interface-only` passed for shared drawer metrics/motion, generated countdown sounds, display selection/placement and two-line Chinese channel descriptions.
- `--self-test --export-only` passed with generated media. The 100% / 75% / 50% / 25% outputs were 1920×1080 / 1440×810 / 960×540 / 480×270 at 30 fps and measured 4,262,767 / 4,109,805 / 1,763,883 / 675,144 bytes. The 0.75 MB custom limit retried to 680,932 bytes. Cancellation, retry and safe window-title naming passed.
- The visual-reference offline checks passed all 63 cases. They are static/minimal-DOM checks, not native-app or physical-device acceptance.
- `--self-test-display-panels` passed on two connected displays: alerts followed the main panel and stayed above it; countdowns were centered, immovable, click-through and non-shareable, with complete cancellation/end cleanup. The existing local Universal package reports `x86_64 arm64`; strict deep signature verification and Info.plist lint passed. No replacement of the installed application or binary release was performed.
- At this preflight revision, the required full `--self-test` failed at `自然修饰模糊了画面背景边缘。` Both the production portrait processor and its diagnostics were unchanged from the upstream baseline.
- A separate temporary synthetic-image probe reproduced the portrait failure: all sampled background-mask values were zero, edge locations stayed unchanged, and the maximum channel difference was one 8-bit level (for example red 128 → 127). An all-black mask produced the same discrepancy. A float32 working context removed that background-edge discrepancy. In a temporary copy, allowing at most one level in only the failing background comparison made the complete portrait diagnostic group pass. That temporary experiment was not included in `697b995`; the subsequent test-only fix is recorded above.
- No real screen recording, microphone session or camera session was started during this preflight. Earlier native layout/interaction checks and their remaining acceptance limits are recorded below. Temporary diagnostic programs and private captures are not included in the commit.

## 2026-10-09: display previews and channel alignment (local, unpublished)

- Release compilation and `--self-test --interface-only` passed. The final Universal App contains `x86_64 arm64`; strict deep signature verification and Info.plist validation passed. No commit, push, PR or replacement of the installed App was performed.
- The native Screen-mode UI was checked with real landscape and portrait displays. Switching the left-side numeric keys updated the selected display, name, resolution and thumbnail. The final 28×28pt keys match the Refresh key, sit below the mode labels and use their right-edge alignment; 40×40pt hit areas are retained. They leave the complete right-hand width for the aspect-preserving image. Both images have matching rounded corners and a closed 1pt inner outline, without an added black canvas. Name and resolution share the raised header row. Main-panel height and the dial anchor are unchanged.
- All four channel captions were visually checked after reducing their description font by 1pt and moving the title/description group toward the bottom. Two-line descriptions and title baselines align; the top switches stay fixed, and the indicator gap increased from 3pt to 5pt only in these four cards. Permission-recovery rows use a shared reserved slot in code; no new camera or microphone authorization was requested for this check.
- `--self-test-display-panels` passed with three connected displays earlier in the session and with the two remaining displays on the final code. It creates only native test panels: alerts follow the main panel on every display and remain above its highest level; countdown panels are centered, immovable, click-through and non-shareable. Cancellation and completion remove all countdown panels. The modal-run-loop placement check covers AppKit's deferred alert-level reset.
- Interface tests cover primary/secondary selection, disconnected-target rejection, empty lists, negative screen origins, portrait arrangements, popup bounds, thumbnail aspect ratios and every two-line Chinese channel description. Single-display button hiding is implemented but was not checked by physically disconnecting a monitor. Display previews stay in memory; no real screen recording, microphone recording or camera session was started.
- Export-only regression passed with generated media: 1920×1080 / 1440×810 / 960×540 / 480×270 at 30 fps measured 4,248,258 / 3,933,071 / 1,843,224 / 669,272 bytes. The 0.75 MB custom ceiling retried from an oversized first attempt to 716,670 bytes. Cancellation, retry and window-title naming passed.
- The required complete `--self-test` was run on the final code but still **did not pass** at the existing, unchanged portrait assertion: `自然修饰模糊了画面背景边缘。` The display/interface/export passes are not a complete regression pass.

## 2026-10-09: relative video sizes and same-window drawers (local, unpublished)

- `swift build -c release` passed. The Universal App contains `x86_64 arm64`; strict deep signature verification and Info.plist validation passed. No commit, push, PR or replacement of the installed App was performed for this local revision.
- `--self-test --interface-only` passed: monotonic damped drawer motion and the three locally generated 90ms countdown ticks. A camera-free native harness also exercised countdown completion and cancellation during the first tick.
- `--self-test --export-only` passed with generated media: 1920×1080 / 1440×810 / 960×540 / 480×270 at 30 fps; measured output sizes 4,246,901 / 4,090,953 / 1,759,296 / 674,159 bytes. The 0.75 MB custom ceiling required a retry and finished at 679,136 bytes. Cancellation, retry and non-overwriting names passed.
- The required complete `--self-test` was run but **did not pass**: the unchanged portrait regression reports `自然修饰模糊了画面背景边缘。` The independent interface/export passes do not imply a complete regression pass.
- Actual native rendering was checked at the final fixed 560pt content height. Window, screen and region modes share the same footprint; region mode with focus-mask corner controls remains fully visible. Recording-key spacing is fixed rather than an expanding spacer.
- With previously granted camera permission, toggling the camera opened the left drawer automatically. All portrait controls and Complete were visible without scrolling; closing the drawer kept the camera enabled, clicking its card reopened it, and switching the camera off closed the drawer. No camera recording was made during this check.
- A generated-media harness checked the final right drawer with Custom size, a simulated three-file saved result, and a long completion warning simultaneously. All controls remained visible without scrolling. An invalid size showed the validation message and disabled export; editing the field worked. Simulated saved paths are layout fixtures, not proof of a real save or Finder reveal.
- Earlier local interaction checks covered idle close/Command-Q, the foreground save guard, slider selection/dragging and standard text-editing shortcuts. Extended live capture, microphone synchronization and every guarded-close state still require acceptance on the final package.
- The adopted visual specification passed all 63 offline checks; that reference page does not serve as acceptance evidence for the new native drawer layout.

### Drawer alignment and full export readouts: same-day follow-up

- Both native cards were visually checked at 354×536pt inside the unchanged 560pt main content height. Headers, closed rounded outlines and bottom action rows align. Portrait Shape and Size are stacked; both drawers use above-control titles, equal-width option buttons and the same divider/spacing components. All controls fit without scrolling.
- Window, Screen and Region mode screenshots retain the source knob at the same anchor; enabling the region focus-mask corner controls does not move it or hide the recording key.
- A generated-media native harness checked Custom size with three simulated saved paths and a long completion warning. Duration, dimensions, frame rate, per-video byte ceiling and the custom recommendation remain visibly displayed. High quality also retains its byte estimate when the warning is present. Simulated saved paths are not evidence of a real save.
- The 44×44pt restart icon sits beside Save / Export Again. There is no export Done button; the unsaved discard entry remains in the header. Clicking Restart with generated unsaved media showed the save-protection confirmation. Choosing Continue Export returned to the original settings without deleting the fixture or starting capture. No destructive confirmation was accepted.
- The earlier same-day export form placed File Name on the left and all five Video Size choices on the right, with the full-width parameter readout beneath them. This layout was subsequently replaced by the full-row slider described below. Custom size, guidance and a long warning fit without scrolling; a pure-audio selection expanded the name field. Editing an invalid filename showed the renamed File Name validation message and disabled export without hiding the dimensions/readout. Export-only regression was rerun and passed the same measured tiers and custom ceiling recorded above.
- The final release build, interface-only check, Universal packaging, strict deep signature verification and plist validation passed. The required complete self-test was rerun and still failed at the existing natural-retouch background-edge assertion noted above. No new live screen, microphone or camera recording was used for this follow-up, and nothing was committed or pushed.

### Full-row Video Size and paired inputs: same-day follow-up

- The native right drawer now puts all five Video Size options on one full-width row above the equal-width File Name and Custom Ceiling (MB) fields. Shared input heights, labels, rounded inner outlines and disabled styling were visually checked. Duration, dimensions, frame rate, byte estimates/ceiling, guidance, a simulated three-file result and a long warning remain visible without scrolling.
- Native interaction with generated media confirmed that High quality disables and grays the ceiling field; switching back to Custom restores editing and retains the entered 1.0 MB. Its size readout updates to 1062×598 / 30 fps / at most 1.0 MB. The name field can be edited independently, including Chinese text. Pure-audio selection hides the video slider and disables the ceiling without disabling the name.
- Window-title naming is snapshotted before countdown; generated tests cover normal Chinese titles, empty-title fallback, path separators/control characters, MP4 suffixes and long compound-emoji titles. This is code/generated-media validation, not a new live-window recording acceptance test.
- Release compilation, interface-only checks, Universal packaging, strict signature verification and plist validation passed. Export-only checks passed: 1920×1080 / 1440×810 / 960×540 / 480×270 at 30 fps measured 4,246,901 / 4,090,953 / 1,760,002 / 674,159 bytes; the 0.75 MB ceiling retried to 679,641 bytes. Naming, cancellation and retry passed. The required complete self-test was rerun and still failed at the unchanged natural-retouch background-edge assertion. No commit, push or PR was made.

### Selected A layout and final control cleanup: same-day follow-up

- The four grey channel cards now use a compact shared layout, original green LEDs, and equal footprints. The orange Record key and primary drawer actions share a 44pt height. Interface text increased by 1pt, with large action captions retained at 15pt; light-key captions use a shared dark grey without inherited text shadow.
- Export header uses “录制” beside the recessed dot-matrix duration. Its saved-count button and separate discard button were removed. One “重新录制” action retains the existing unsaved-media guard and direct restart behavior. Portrait drawer uses Complete and Escape; its redundant header close button was removed.
- Window mode uses a scrolling list with one-line application and window titles, selected green LED, and a fine closed inset outline. Real clicks on generated entries verified selecting the second entry, scrolling to the end, and selecting the final entry. No real user window names were used in these fixtures.
- Persistent source descriptions were removed from all three modes. Region option descriptions are tooltip-only, and the three rows retain 44pt minimum heights. All video export parameter readouts are centered; High and Custom actual native renders were inspected.
- Generated-media UI checks exercised five quality labels, invalid filename and size guards, audio-only selection, empty selection, merge/separate output, protected close/restart and cancellation. Actual first save created three tracks; repeat save created six files and left the first three SHA-256 values unchanged. Portrait position, shape, size, preset, mirror, Complete and Escape controls passed without opening camera hardware.
- Release compilation, interface-only checks, 21 selected-HTML checks, Universal packaging, strict signature verification and plist validation passed. The required full self-test still fails at the existing natural-retouch background-edge assertion. Automatic coordinate dragging of the native video slider did not change its selection; this check remains incomplete despite successful preset-label clicks. These results do not establish a full regression pass or physical camera/microphone acceptance.
- All changes are local and unpublished. The installed App has not been replaced.

## v1.5.0 build 20: merged window and interaction updates

2026-10-03. Packages the current main branch through merged PR #15 (`fa4e255`), including PR #14. Version metadata, current download links and product specifications advance to 1.5.0 / build 20. This release adds no further runtime changes beyond those merged PRs.

- `swift build -c release`, the complete `.build/release/SnapRecorder --self-test`, and the self-test from the ZIP-extracted Universal App passed. The natural-retouch background-edge assertion reported in the PR descriptions did not reproduce on this machine.
- The Instrument specification passed all 63 offline checks.
- Built and extracted Apps pass strict deep signature verification, contain `x86_64 arm64`, report 1.5.0 / build 20, and have byte-identical executables.
- The ZIP contains only the executable, Info.plist, icon and signature resources. No recordings, audio, screenshots, logs or test media are packaged. The stripped executable contains no local user-home path.
- Package: `Snap-Recorder-v1.5.0-macOS-universal.zip`, 2,229,048 bytes; SHA-256 `1bfd6f0e36da28f5a471058ea6f94eefcab8b2a458b1b0e96729b2ab615a3aab`.
- The installed App was replaced from the verified ZIP after confirming the old App was idle and preserving a rollback archive. Its signature and executable match the package. Launch inspection confirms the new “任意窗口” source and normal setup controls.
- These generated-media and launch checks do not claim a new live screen, microphone or camera acceptance pass. GitHub publication and public download are separate release steps.

## Instrument product page and visual philosophy

2026-09-30. The existing GitHub Pages site adopts the Instrument palette and material system: aluminum panels, graphite keys, recessed readouts and mechanical markings. README adds the design philosophy and links to the adopted specification. The App remains 1.1.1 / build 18; no recording/export code or package has changed.

- Local Chromium checks passed at 1440, 1100, 960, 850, 768, 650, 390 and 320 CSS pixels: no horizontal overflow, missing images, missing anchor targets or page errors. Both download buttons point to the 1.1.1 Universal release.
- Desktop and phone-size renderings were visually inspected. The two real macOS screenshots retain at least two source pixels per displayed CSS pixel; original-resolution links are available. README displays each 1120-pixel image at no more than 560 CSS pixels.
- Keyboard skip navigation, the download anchor and reduced-motion behavior passed. The page requires no JavaScript, third-party fonts or additional services. Website color variables are aligned with `视觉规范/器物/instrument.css`; orange stays reserved for the recording identity.
- `swift build -c release` and the complete `.build/release/SnapRecorder --self-test` passed. This is a website/documentation check, not a new live screen, microphone or camera test.

## v1.1.1 build 18: Instrument application icon

2026-09-30. The application, README and product page now use the same Instrument icon: a brushed-aluminum body, recessed graphite dial, mechanical tick marks and the signal-orange recording lamp. Recording and export source behavior is unchanged from v1.1.0.

- `assets/SnapRecorderIcon.svg` and `docs/images/snap-recorder-icon.svg` are byte-identical, valid SVG files. The source was visually checked at 1024, 128 and 32 pixels; the signal lamp and dial remain recognizable at the smallest size.
- The build-generated `SnapRecorderIcon.icns` was extracted back into all required 16–1024 pixel iconset entries. A 128-pixel entry was visually checked and matches the adopted icon.
- `swift build -c release`, `.build/release/SnapRecorder --self-test` and the self-test from the extracted Universal App passed. The Instrument specification passed all 63 offline checks.
- The built and extracted Apps pass strict signature verification, contain `x86_64 arm64`, report 1.1.1 / build 18, and have byte-identical executables and icon resources.
- The ZIP contains only the executable, Info.plist, icon and signature resources. It contains no recordings, audio, logs or test media.
- Release candidate: `Snap-Recorder-v1.1.1-macOS-universal.zip`, 2,173,159 bytes; SHA-256 `2e55945d9f4ca12571fda78d41fa78310fcf6d098b773460eb44eb3df07896f7`.

## v1.1.0 build 17: instrument visual system and release candidate

2026-09-30. The main panel, export workspace, countdown, recording HUD, camera settings and region overlay now share the adopted Instrument visual system. Recording and export behavior keep the existing state and model calls.

- `swift build -c release` and `.build/release/SnapRecorder --self-test` passed, including repeat export, measured size tiers, custom byte ceilings, all audio/content arrangements, camera compositing, pause alignment and native portrait processing.
- The Instrument specification passed all 63 offline checks for structure, accessibility labels, local-only resources, forbidden APIs, contrast, export planning, simulated workflow and edge states.
- The README and product page use 2x images captured from this build: 1120x1234 for the main region setup and 1120x984 for the export workspace.
- The Universal App and the extracted App both pass strict signature verification. The executable contains `x86_64 arm64`, reports 1.1.0 / build 17, and is byte-identical before and after packaging.
- The ZIP contains only the executable, Info.plist, icon and signature resources. It contains no recordings, audio, screenshots, logs or test media.
- Release candidate: `Snap-Recorder-v1.1.0-macOS-universal.zip`, 2,332,255 bytes; SHA-256 `a80b85e440c243276ef7e25834cd1f4a0fc6ff607b55b118703f595a2626d7cb`.
- Darkroom, Folio and the three-direction comparison were moved to the desktop visual archive. The repository retains only the adopted Instrument specification and implementation.
- The built App was launched and its red close button was clicked through the real macOS interface. Its process exited immediately. Countdown, capture, retryable save and active export states still route through the existing safety prompts before the window can close.

## v1.0.0 build 15: first 1.0 release package

2026-09-21. The first 1.0 release packages the merged PR #9 feature source, without additional runtime changes from the verified local 0.5.1 candidate below. Version metadata, release notes and download links are advanced to 1.0.0 / build 15.

- The Universal package was rebuilt for `x86_64 arm64`. Its own executable passed the complete generated-media self-test, including 30 fps, tiered/custom output, content/audio combinations, cancellation and repeat export, camera overlay and portrait regression checks.
- The App reports 1.0.0 / build 15. Strict signature verification passed before and after ZIP extraction; the extracted executable is byte-identical to the build.
- The ZIP contains only the executable, Info.plist, icon and signature resources. No recordings, audio, test media, logs or local user-home paths are packaged. ZIP SHA-256: `24e3959f2c722403bdb10d26836ea6542c0ee521e8857b7157464c3bcf23c858`.
- This package validation does not claim a new real screen, microphone or camera acceptance pass; the tests use generated media.
- Release CI, GitHub publication, public download and Pages deployment must be verified against this package before reporting publication complete.

## v0.5.1 build 14: 30 fps export and custom-size guidance (local build)

2026-09-21. Built from the merged PR #9 source at `3136efdd506521242aae0e9e6676a4b487e375c8`, with the bundle version advanced to 0.5.1 / build 14. This record covers the local package; GitHub publication and replacement of the installed App have not been performed.

- Release compilation and the complete media self-test passed. The generated 1080p60 source exported at 30 fps for all four tiers: 4,281,006 / 1,872,349 / 613,887 / 191,104 bytes. These are synthetic fixture results, not a guaranteed real-world compression ratio.
- Custom-size lower bounds and actual byte ceilings, naming, cancellation, retry, repeated exports, all content subsets/arrangements, audio isolation and alignment, camera overlay/mirroring/pause, and native portrait feature/background protection passed.
- The Universal App contains `x86_64 arm64`, reports 0.5.1 / build 14, and passes strict signature verification before and after ZIP extraction. The extracted executable is byte-identical to the packaged build.
- The ZIP contains exactly the executable, Info.plist, icon and signature resources. No recordings, audio, test media or logs are included, and the executable contains no local user-home path. ZIP SHA-256: `1bebd35688f05820217db17bff53bbcf902bd276034508bf2d6d409a799fb1bd`.
- The merged feature commit passed GitHub CI before packaging. No new live screen, microphone or camera acceptance is claimed for this version.

## v0.5.0 build 13: simplified export and shareable main panel

2026-09-19. Build 13 supersedes the local build 12 below. The installed `/Applications/Snap Recorder.app` matches the verified Universal 2 executable and passes strict signature verification. The previous local App is preserved in the dated rollback folder.

- Release build and the complete media self-test passed. The final interface has only Merge / Separate; all 7 nonempty content subsets in both modes are tested (14 combinations), including silent video, individual audio, mixed audio, alignment, repeat export, name collisions, cancellation and byte limits. Existing camera/portrait regression tests still pass with generated media.
- The real export UI was visually checked with generated fixtures: narrow Merge / Separate controls, bordered content/mode/size groups, distinct name spacing, and outlined Discard This Recording / Record Again buttons. Renaming and separate export generated 3 files; switching to Merge generated a fourth without replacing the previous files. The saved/custom-size layout retains visible controls.
- A screenshot of the normal installed main panel contains the visible UI; it no longer returns a blank image. This no longer depends on a test-only window-sharing exception.
- Explicit `--self-test-window-capture` passed using the production main-window factory and the production region capture/export pipeline. It captures only the interior of a generated green panel. The main-window identity is resolved before hide/show; a red helper panel is created after recording begins and deliberately made shareable. All three decoded-frame samples retain the green main-panel content and exclude the helper. The test media is removed afterward. This checks the application filter's handling of later-created windows, beyond the auxiliary panels' own `.none` sharing flags.
- Screen and region modes share that same application-exclusion filter with the main panel as the sole exception. Countdown, recording HUD, camera preview and region overlay remain auxiliary excluded windows. The menu-bar entry and reopening the application can show the main panel during recording. Browser capture remains limited to the selected independent browser window.
- The ZIP inventory contains only the App executable, Info.plist, icon and signature. No media, screenshot, debug log, credentials or test fixture is packaged. The staged source changes introduce no media files. ZIP SHA-256: `bbf12b1cfba15b63604afba3299a9cae7d7feab4b64e4eaa5a793cf28673229d`.

The real screen test is narrowly scoped to generated window content. It does not claim a new live microphone/camera pass, extended real-world recording, or manual drag/HUD-button validation on every macOS/hardware combination. GitHub CI and download checksum verification remain release gates; historical device results are below.

## v0.5.0 build 12: flexible export workspace (local, unpublished)

2026-09-19. The installed `/Applications/Snap Recorder.app` is updated to 0.5.0 build 12. Its executable and Info.plist are byte-identical to the verified Universal 2 build. The previous 0.4.0 build 11 App is preserved in the dated local rollback folder. No GitHub push or public release was performed.

Completed checks:

- `swift build -c release` and the complete `.build/release/SnapRecorder --self-test` passed. Universal arm64/x86_64 packaging and strict code-signature verification passed. The installed App opens its normal capture setup; microphone and camera remain off, and existing screen permission is available.
- A generated 4-second 1080p60 stress clip exercises all four tiers from the same source: approximately 12.01 / 1.87 / 0.61 / 0.21 MB. High retained the master after the fidelity check. A custom 0.35 MB export stayed under its measured limit. A custom limit larger than the source preserves the source bytes. These results describe the synthetic content, not a universal compression ratio.
- Decoded audio checks cover all 7 nonempty content subsets and each valid arrangement (16 combinations): video, computer sound, and microphone separately; one mixed MP4; voice separate with computer audio retained in video; and audio-only separate/mixed output. Distinct 440 Hz and 880 Hz tones check both retained and excluded sources. Output track presence and effective durations are checked, with a 40 ms tolerance. Pure audio ignores irrelevant video size settings.
- Removing audio and mixing voice both preserve compressed video samples at those steps. Size optimization is a separate, explicit video encoding stage. Audio-only mixing writes an exact aligned PCM timeline before AAC encoding so silent heads/tails are preserved.
- Tests cover name validation, shared collision suffixes, custom caps including mixed sound, cancellation, retry, failed destination recovery, repeated export from the same master, and cleanup that preserves previously saved exports. Existing capture sizing, camera composition/motion/pause, and native portrait tests also pass.
- An isolated App using the final executable and generated media exercised the real export UI without requesting capture permissions: content checkboxes, single arrangement selection, default voice separation, rename before save, all-separate three-file output, repeated system-only export with collision suffix, zero-size rejection, audio-only settings hiding, mixed M4A export, then a combined MP4 under a 0.3 MB cap. Saved files remain listed and settings remain editable. “完成” returns to setup. An unsaved fixture also returns directly to setup through “放弃录制”, without an export.
- Visual inspection of the isolated UI confirms short mode titles, no repetitive button subtitles, and visible confirmation controls before and after save. Only the generated-media preview bundle permits screenshots; normal capture windows/HUD remain non-shareable.
- All fixtures are generated locally. No test recording, audio file, archive, or personal media was added to the repository.

Remaining evidence boundary: this build has not been used for a new real screen/microphone/camera recording. Long recordings, physical acoustic spill from speakers into the microphone, actual restart countdown with live sources, hardware permission/error cases, and different Intel Mac encoders remain real-device acceptance work. Earlier version hardware results below are historical, not new-build coverage. Export research and measured budgets are documented in [export-redesign.md](export-redesign.md).

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
- Record the same changing scene once, export each size tier repeatedly from its source, and compare file size/text clarity; compact tiers have progressively smaller dimension and frame-rate ceilings.
- Full screen: start, pause, resume, stop, and confirm auxiliary windows are excluded; intentionally showing the main panel inside the frame includes it.
- Microphone off: stopping opens naming and export settings; missing voice is unavailable; the default exports one MP4.
- Microphone on + computer audio on: verify both combined and separate export.
- Microphone on + computer audio off: verify combined voice-only video and separate silent-video + M4A output.
- All content selected: “分轨” creates silent MP4 + system M4A + voice M4A, and “合并” creates one MP4. No ZIP.
- Deselect video and export either independent audio or a single mixed M4A. Change the arrangement and export again without ending the session.
- Rename before saving, verify collisions never overwrite, cancel an export, discard before saving, and restart using the same capture source.
- Confirm final MP4 dimensions stay within the selected tier, preserve the source aspect ratio, and play in QuickTime.
- Confirm the standalone M4A and MP4 effective playback timelines differ by no more than 40 ms.
- Deny microphone permission once and confirm recording does not start until permission is restored.
- Inspect the built App and release archive for personal names, email addresses, local paths, recordings, logs, and build caches.

## Release build checks

```bash
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "build/Snap Recorder.app"
du -sh "build/Snap Recorder.app"
```
