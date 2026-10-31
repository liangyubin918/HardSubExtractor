import Foundation

enum SubtitleExporter {

    static func srt(_ segments: [SubtitleSegment]) -> String {
        var output = ""
        var index = 1
        for segment in segments where !segment.isBlank {
            output += "\(index)\n"
            output += "\(segment.start.srtTimecode) --> \(segment.end.srtTimecode)\n"
            output += segment.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            index += 1
        }
        return output
    }

    static func webVTT(_ segments: [SubtitleSegment]) -> String {
        var output = "WEBVTT\n\n"
        for segment in segments where !segment.isBlank {
            let start = segment.start.srtTimecode.replacingOccurrences(of: ",", with: ".")
            let end = segment.end.srtTimecode.replacingOccurrences(of: ",", with: ".")
            output += "\(start) --> \(end)\n"
            output += segment.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return output
    }

    static func plainText(_ segments: [SubtitleSegment]) -> String {
        segments
            .filter { !$0.isBlank }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
    }
}
