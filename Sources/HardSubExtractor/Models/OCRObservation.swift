import Foundation

/// 单条字幕行（锚点）在一帧上的 OCR 结果。
/// 空字符串表示「这一行的字幕刚消失」，聚合器依赖这个信号来精确收尾。
struct OCRObservation {
    /// 属于哪一条字幕行
    var anchorID: UUID
    var time: TimeInterval
    var frameEnd: TimeInterval
    var text: String
    var confidence: Double

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
