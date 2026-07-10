# Contributing

Thanks for helping improve Snap Recorder.

## Product principles

- Keep the recording flow short and obvious.
- Preserve browser-window isolation and native-pixel output.
- Do not add an editor, cloud upload, account system, or complex export settings.
- Keep recordings local and request permissions only when a feature needs them.

## Development

Requirements: macOS 14 or newer and current Xcode Command Line Tools.

```bash
swift build -c release
.build/release/SnapRecorder --self-test
./scripts/build-app.sh
```

Before opening a pull request:

1. Run the release build and self-test.
2. Test both browser-window and full-screen capture when changing the capture path.
3. Test microphone off, combined export, separate export, and selecting both export modes when changing audio code.
4. Do not commit recordings, personal paths, credentials, build products, or permission databases.

Please keep pull requests focused and explain the user-visible behavior that changed.
