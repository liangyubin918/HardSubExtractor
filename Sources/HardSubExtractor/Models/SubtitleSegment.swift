import Foundation

/// 一条字幕（一句台词），时间单位统一使用秒。
struct SubtitleSegment: Identifiable, Hashable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var confidence: Double = 0
    /// 由聚合器判定的疑似水印 / 台标 / 片头 logo，导出时可选择过滤
    var isSuspectedWatermark: Bool = false

    var duration: TimeInterval { max(0, end - start) }

    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }
}

extension TimeInterval {
    /// 00:00:01,250 形式的 SRT 时间码
    var srtTimecode: String {
        let totalMS = Int((max(0, self) * 1000).rounded())
        let h = totalMS / 3_600_000
        let m = (totalMS % 3_600_000) / 60_000
        let s = (totalMS % 60_000) / 1000
        let ms = totalMS % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// 01:23.4 形式的界面上显示用时间码
    var shortTimecode: String {
        let total = max(0, self)
        let m = Int(total) / 60
        let s = total - Double(m * 60)
        return String(format: "%02d:%04.1f", m, s)
    }
}
