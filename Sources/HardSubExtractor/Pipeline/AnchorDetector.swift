import Foundation
import CoreGraphics
import AVFoundation

struct AnchorDetectionConfig {
    /// 扫描采样间隔（秒）
    var sampleInterval: Double = 1.0
    /// 最多扫描片头多少秒
    var maxScanSeconds: Double = 180
    /// 一个候选行至少要在多少帧里出现才算锚点
    var minHits: Int = 6
    /// 采到这么多样本后，若已经稳定就提前结束
    var earlyStopSamples: Int = 45
    /// 用哪套解码器
    var decoder: VideoDecoderKind = .auto
    /// 在画面的哪个范围内找字幕（归一化，左上原点）
    var searchROI = CGRect(x: 0.02, y: 0.58, width: 0.96, height: 0.42)
}

/// 扫描片头，自动找出字幕行在画面上的位置。
///
/// 这是从望言OCR（nhjydywd/SubtitleOCR）学来的核心设计：
/// 与其让用户拿一个固定矩形去猜，不如先用几秒钟把「字幕在哪几行」测出来，
/// 后面每一行独立处理。固定矩形的问题是它必然在「放宽漏句」和「收紧切字」之间摇摆。
enum AnchorDetector {

    struct Result {
        var anchors: [SubtitleAnchor]
        var scannedSeconds: Double
        var samples: Int
    }

    private struct Candidate {
        var centerY: CGFloat
        var height: CGFloat
        var minX: CGFloat
        var maxX: CGFloat
        var text: String
    }

    static func detect(url: URL,
                       config: AnchorDetectionConfig,
                       recognizer: any SubtitleRecognizer,
                       onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> Result {

        // 第一轮用快速模式（快好几倍）。它偶尔会漏检小字或低对比的字幕，
        // 所以一旦一行都没找到，就用精确模式重扫一遍 —— 分析只做一次，多花这点时间值得。
        let fast = try await scan(url: url, config: config,
                                  recognizer: recognizer.detectionVariant(),
                                  onProgress: onProgress)
        if !fast.anchors.isEmpty { return fast }

        onProgress(0, "快速模式没找到，改用精确模式")
        return try await scan(url: url, config: config,
                              recognizer: recognizer,
                              onProgress: onProgress)
    }

    private static func scan(url: URL,
                             config: AnchorDetectionConfig,
                             recognizer: any SubtitleRecognizer,
                             onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> Result {

        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let scanLimit = duration > 0 ? min(duration, config.maxScanSeconds) : config.maxScanSeconds

        let reader = try await VideoFrameReader(url: url,
                                                minInterval: config.sampleInterval,
                                                decoder: config.decoder)
        var candidates: [Candidate] = []
        var samples = 0
        var lastTime: Double = 0

        while let frame = await reader.next() {
            if Task.isCancelled { break }
            lastTime = frame.time
            if frame.time > scanLimit { break }

            guard let cropped = PixelToolkit.shared.cropBuffer(from: frame.pixelBuffer,
                                                              normalizedROI: config.searchROI,
                                                              scale: 1.0) else { continue }
            let lines = (try? await recognizer.recognize(pixelBuffer: cropped)) ?? []
            samples += 1

            for line in lines {
                let box = line.boundingBox
                // 把裁剪图里的归一化坐标（左下原点）映射回整帧（左上原点）
                let height = box.height * config.searchROI.height
                let topY = config.searchROI.minY + (1 - box.maxY) * config.searchROI.height
                let minX = config.searchROI.minX + box.minX * config.searchROI.width
                let maxX = minX + box.width * config.searchROI.width
                candidates.append(Candidate(centerY: topY + height / 2,
                                            height: height,
                                            minX: minX,
                                            maxX: maxX,
                                            text: line.text))
            }

            if samples > 0, scanLimit > 0 {
                onProgress(min(1, frame.time / scanLimit), "分析字幕 \(samples) 帧")
            }

            // 够多帧之后，如果已经找到稳定的行就不再往下扫
            if samples >= config.earlyStopSamples {
                let clusters = cluster(candidates, minHits: config.minHits)
                if clusters.count >= 1 {
                    break
                }
            }
        }
        await reader.cancel()

        let clusters = cluster(candidates, minHits: config.minHits)
        let anchors = buildAnchors(from: clusters, searchROI: config.searchROI)
        onProgress(1, anchors.isEmpty ? "没找到字幕行" : "找到 \(anchors.count) 行字幕")
        return Result(anchors: anchors, scannedSeconds: lastTime, samples: samples)
    }

    // MARK: - 纵向聚类

    private static func cluster(_ candidates: [Candidate], minHits: Int) -> [[Candidate]] {
        guard !candidates.isEmpty else { return [] }

        var groups: [[Candidate]] = []
        for candidate in candidates.sorted(by: { $0.centerY < $1.centerY }) {
            var placed = false
            for index in groups.indices {
                guard let reference = groups[index].first else { continue }
                let tolerance = max(reference.height, candidate.height) * 0.6
                let heightRatio = candidate.height / max(reference.height, 0.0001)
                if abs(candidate.centerY - reference.centerY) <= tolerance,
                   heightRatio > 0.55, heightRatio < 1.8 {
                    groups[index].append(candidate)
                    placed = true
                    break
                }
            }
            if !placed { groups.append([candidate]) }
        }

        return groups.filter { $0.count >= minHits }
    }

    private static func buildAnchors(from groups: [[Candidate]], searchROI: CGRect) -> [SubtitleAnchor] {
        var anchors: [SubtitleAnchor] = []

        for group in groups {
            let centers = group.map(\.centerY).sorted()
            let heights = group.map(\.height).sorted()
            let lefts = group.map(\.minX).sorted()
            let rights = group.map(\.maxX).sorted()

            let centerY = median(centers)
            // 高度用 p75 再放大一点：Vision 返回的框偏紧，
            // 带太窄会时而漏字、时而只切到半个字形（实测会冒出 "/Hard" 这类碎片）。
            let height = max(percentile(heights, 0.75) * 1.2, 0.010)
            let observedLeft = percentile(lefts, 0.10)
            let observedRight = percentile(rights, 0.90)
            guard observedRight > observedLeft else { continue }

            // 宽度不能只取观测到的最宽值 —— 后面出现更长的台词就会被切掉。
            // 纵向band 才是「行」的定义，横向放宽到足够容纳更长的句子。
            let observedWidth = observedRight - observedLeft
            let centerX = (observedLeft + observedRight) / 2
            let width = min(max(observedWidth * 1.35, 0.42), searchROI.width)
            var left = centerX - width / 2
            left = min(max(left, searchROI.minX), max(searchROI.minX, searchROI.maxX - width))

            // 语种取多数票
            var votes: [SubtitleLanguage: Int] = [:]
            for candidate in group {
                votes[SubtitleLanguage.classify(candidate.text), default: 0] += 1
            }
            let language = votes.max { $0.value < $1.value }?.key ?? .unknown

            anchors.append(SubtitleAnchor(rect: CGRect(x: left,
                                                       y: centerY - height / 2,
                                                       width: width,
                                                       height: height),
                                          language: language,
                                          isPrimary: false,
                                          hits: group.count,
                                          maxWidth: observedWidth))
        }

        anchors.sort { $0.centerY < $1.centerY }

        // 最靠下的一行是主字幕：影视字幕基本都在画面下方
        if let lowest = anchors.indices.max(by: { anchors[$0].centerY < anchors[$1].centerY }) {
            anchors[lowest].isPrimary = true
        }
        return anchors
    }

    private static func median(_ sorted: [CGFloat]) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func percentile(_ sorted: [CGFloat], _ ratio: Double) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * ratio)))
        return sorted[index]
    }
}
