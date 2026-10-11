#!/usr/bin/env python3
"""Render the production SwiftUI views at 3x, without capturing the desktop.

Only the temporary screenshot executable receives fixture-only model setters.
The app's sources and behavior are unchanged. No device, window-list or cursor
capture is used. Run on macOS: python3 scripts/render-marketing-screenshots.py
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/images/v2.0"

FIXTURE = r'''
extension AppModel {
    func revealMarketingScene(_ scene: String) {
        permissionGranted = true
        // The initial view lifecycle clears previews while permission=false.
        if scene == "display" { displayThumbnail = MarketingScreenshots.demoDisplay() }
    }

    func configureMarketingScene(_ scene: String) {
        permissionGranted = false
        mode = scene == "region" ? .region : scene == "display" ? .display : .window
        availableWindows = [
            ("Safari", "新产品，一分钟看懂", "com.apple.Safari"),
            ("Keynote", "把好想法讲清楚", "com.apple.iWork.Keynote"),
            ("Figma", "下一版，从这里开始", "com.figma.Desktop"),
            ("备忘录", "灵感，随时记下来", "com.apple.Notes")
        ].enumerated().map { index, item in
            CaptureWindowInfo(id: UInt32(100 + index), processID: 0,
                applicationName: item.0, bundleIdentifier: item.2, title: item.1,
                isOnScreen: true, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                size: CGSize(width: 2560, height: 1600))
        }
        selectedWindowID = 100
        availableDisplays = [
            CaptureDisplayInfo(id: 1, name: "Studio Display", pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true),
            CaptureDisplayInfo(id: 2, name: "内建显示器", pixelSize: CGSize(width: 3024, height: 1964), isPrimary: false)
        ]
        selectedDisplayID = 1
        displayThumbnail = MarketingScreenshots.demoDisplay()
        captureRegion = CaptureRegion(displayID: 1, sourceRect: CGRect(x: 0, y: 0, width: 1280, height: 720))
        isFocusMaskEnabled = scene == "region"
        isRegionSelectionLocked = scene == "region"
        if scene == "portrait" {
            capturesCamera = true
            cameraReady = true
            cameraSettings.portrait.preset = .natural
        }
        if scene == "export" {
            phase = .choosingExport
            exportName = "一分钟产品演示"
            exportInfo = RecordingExportInfo(duration: 62, size: CGSize(width: 2560, height: 1440),
                sourceBytes: 48_000_000, hasSystemAudio: true, sourceVideoBitrate: 6_000_000,
                sourceFrameRate: 30, hasMicrophone: true)
            selectedExportTracks = [.video, .systemAudio, .voice]
            selectedExportArrangement = .separate
            selectedQualityPreset = .balanced
            customSizeMegabytes = "20"
        }
    }
}
'''

def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="snap-marketing-") as temporary:
        scratch = Path(temporary)
        model = scratch / "AppModel.swift"
        model.write_text((ROOT / "Sources/SnapRecorder/AppModel.swift").read_text() + FIXTURE)
        sources = sorted(p for p in (ROOT / "Sources/SnapRecorder").glob("*.swift")
                         if p.name not in {"AppModel.swift", "SnapRecorderApplication.swift"})
        executable = scratch / "RenderScreenshots"
        subprocess.run(["swiftc", "-O", "-swift-version", "5", "-parse-as-library",
                        *map(str, sources), str(model),
                        str(ROOT / "scripts/MarketingScreenshots.swift"), "-o", str(executable)], check=True)
        for scene in ["main", "region", "display", "portrait", "export"]:
            arguments = [str(executable), scene, str(OUTPUT / f"{scene}.png")]
            if scene == "portrait":
                arguments.append("--preview-camera-drawer")
            subprocess.run(arguments, check=True)

if __name__ == "__main__":
    main()
