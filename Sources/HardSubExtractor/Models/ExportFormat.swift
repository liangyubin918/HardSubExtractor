import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt
    case txt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .srt: return "SRT 字幕 (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .txt: return "纯文本 (.txt)"
        }
    }

    var fileExtension: String { rawValue }
}
