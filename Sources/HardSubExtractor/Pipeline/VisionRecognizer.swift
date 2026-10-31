import Foundation
import Vision
import CoreVideo

/// 基于 Apple Vision 的识别器。完全离线、无第三方依赖、无额外包体积。
/// 对干净的影视字幕（白字 + 黑描边、横排）准确率约 85~92%，
/// 通过「区域放大 + 行级置信度过滤 + 语言纠正」可以把常见片源再往上拉几个点。
struct VisionRecognizer: SubtitleRecognizer {
    var languages: [String] = ["zh-Hans", "en-US"]
    var usesLanguageCorrection: Bool = true
    var minimumConfidence: Double = 0.35
    var minimumTextHeight: Double = 0.012
    /// .fast 比 .accurate 快好几倍，用来做「只找位置」的字幕行分析足够
    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate

    var displayName: String { "Apple Vision" }
    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }

    func recognize(pixelBuffer: CVPixelBuffer) async throws -> [RecognizedLine] {
        do {
            return try await performRecognition(on: pixelBuffer, languages: languages)
        } catch {
            // 某些系统版本对不支持的语种组合会直接抛错，退化成默认语种再试一次
            guard !languages.isEmpty else { throw error }
            return try await performRecognition(on: pixelBuffer, languages: [])
        }
    }

    func detectionVariant() -> any SubtitleRecognizer {
        // Vision 的 .fast 引擎只支持 6 种拉丁语系，完全不支持中文 / 日文 / 韩文。
        // 对中日韩内容用 .fast 会一行都认不出来，必须留在 .accurate。
        let needsCJK = languages.contains {
            $0.hasPrefix("zh") || $0.hasPrefix("ja") || $0.hasPrefix("ko")
        }
        guard !needsCJK else { return self }

        var fast = self
        fast.recognitionLevel = .fast
        fast.usesLanguageCorrection = false
        fast.minimumConfidence = 0.2
        fast.minimumTextHeight = 0.008
        return fast
    }

    private func performRecognition(on pixelBuffer: CVPixelBuffer,
                                    languages: [String]) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RecognizedLine], Error>) in
            // Vision 在个别系统版本上会既调请求 completion 又从 perform 抛错，
            // 双重 resume 会直接崩溃，用一次性包装挡住。
            final class ResumeGate {
                private let lock = NSLock()
                private var resumed = false
                private let continuation: CheckedContinuation<[RecognizedLine], Error>

                init(_ continuation: CheckedContinuation<[RecognizedLine], Error>) {
                    self.continuation = continuation
                }

                func resume(returning value: [RecognizedLine]) {
                    lock.lock()
                    let first = !resumed
                    resumed = true
                    lock.unlock()
                    if first { continuation.resume(returning: value) }
                }

                func resume(throwing error: Error) {
                    lock.lock()
                    let first = !resumed
                    resumed = true
                    lock.unlock()
                    if first { continuation.resume(throwing: error) }
                }
            }
            let gate = ResumeGate(continuation)

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    gate.resume(throwing: RecognizerError.failed("Vision 识别失败：\(error.localizedDescription)"))
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [RecognizedLine] = []

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    guard Double(candidate.confidence) >= self.minimumConfidence else { continue }

                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    // 字幕行不可能是贯穿整个画面的超长条，过滤掉检测噪声
                    let box = observation.boundingBox
                    guard box.height <= 0.9 else { continue }

                    lines.append(RecognizedLine(text: text,
                                                confidence: Double(candidate.confidence),
                                                boundingBox: box))
                }

                // Vision 的 boundingBox 是左下角原点，midY 越大越靠上
                lines.sort { lhs, rhs in
                    if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.02 {
                        return lhs.boundingBox.midY > rhs.boundingBox.midY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }

                gate.resume(returning: lines)
            }

            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = usesLanguageCorrection
            request.minimumTextHeight = Float(minimumTextHeight)
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: .up,
                                                options: [:])
            do {
                try handler.perform([request])
            } catch {
                gate.resume(throwing: RecognizerError.failed("Vision 执行失败：\(error.localizedDescription)"))
            }
        }
    }
}
