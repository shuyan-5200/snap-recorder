import Foundation

enum TimeFormatting {
    static func recordingDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func outputFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Snap 录屏 \(formatter.string(from: date)).mp4"
    }

    static func separateVideoOutputURL(matching recordingURL: URL) -> URL {
        siblingOutputURL(
            matching: recordingURL,
            replacingPrefixes: ["Snap 录屏 "],
            with: "Snap 视频 ",
            pathExtension: "mp4",
            fallbackSuffix: "视频"
        )
    }

    static func voiceOutputURL(matching videoURL: URL) -> URL {
        siblingOutputURL(
            matching: videoURL,
            replacingPrefixes: ["Snap 视频 ", "Snap 录屏 "],
            with: "Snap 人声 ",
            pathExtension: "m4a",
            fallbackSuffix: "人声"
        )
    }

    private static func siblingOutputURL(
        matching sourceURL: URL,
        replacingPrefixes: [String],
        with replacementPrefix: String,
        pathExtension: String,
        fallbackSuffix: String
    ) -> URL {
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let resolvedName: String
        if let prefix = replacingPrefixes.first(where: { sourceName.hasPrefix($0) }) {
            resolvedName = sourceName.replacingOccurrences(
                of: prefix,
                with: replacementPrefix,
                options: [.anchored]
            )
        } else {
            resolvedName = "\(sourceName) - \(fallbackSuffix)"
        }
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent(resolvedName)
            .appendingPathExtension(pathExtension)
    }
}
