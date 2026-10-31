import Foundation
import CoreVideo
import CoreGraphics

struct RecognizedLine {
    var text: String
    var confidence: Double
    /// 相对输入图像的归一化矩形，左下角原点（Vision 的约定）
    var boundingBox: CGRect
}

/// OCR 引擎抽象。整个应用只依赖这个协议，
/// 换引擎（Vision → PaddleOCR → 云端 API）不需要动聚合逻辑和 UI。
protocol SubtitleRecognizer: Sendable {
    var displayName: String { get }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    func recognize(pixelBuffer: CVPixelBuffer) async throws -> [RecognizedLine]
    /// 用于「只找字幕行位置」的轻量版本，允许牺牲文字精度换速度
    func detectionVariant() -> any SubtitleRecognizer
}

extension SubtitleRecognizer {
    /// 默认就用自己；支持快速模式的引擎覆盖它
    func detectionVariant() -> any SubtitleRecognizer { self }
}

enum RecognizerError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

enum OCREngine: String, CaseIterable, Identifiable {
    case vision
    case paddle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vision: return "Apple Vision"
        case .paddle: return "PaddleOCR (ONNX)"
        }
    }
}
