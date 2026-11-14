import Foundation

/// 语音活动区间：能量包络上「有人在说话」的时间段
struct SpeechSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

/// 把字幕段时间边界吸附到语音活动边界。
///
/// 字幕时间轴精度受抽帧间隔限制（默认 0.1s）；而字幕出现/消失几乎总是与
/// 开口/停顿对齐的，所以先用音频能量做一次 VAD，再把边界挪到最近的
/// 语音起点/终点。音频特征处理方式借鉴 sushi（12kHz 包络、能量归一化），
/// 但不做跨视频模板匹配——这是自我精修，不是跨版本对齐。
///
/// 只在窗口内小步挪动，OCR 本身的判定仍然说了算：音频只负责把
/// 「知道附近有边界」修得更准，不负责发明新字幕。
enum SpeechSnapper {

    /// 只承认 ±window 内的吸附，避免把边界拖到不相干的语音上
    static let maxSnap: TimeInterval = 0.35
    /// 小于这个调整量不值得动（避免抖动）
    static let minAdjustment: TimeInterval = 0.04

    // MARK: - VAD 参数

    /// 噪声底候选：静音分位数。对白密集的片子里静音占比可能低于这个分位，
    /// 此时纯分位数会落在语音能量上、阈值高到什么都检不出来——
    /// 所以再算一个「中位数 − 20dB」兜底，取两者更低的那个。
    static let noiseFloorPercentile = 0.20
    /// 中位数兜底的裕量
    static let medianFallbackMarginDB: Float = 20
    /// 进入语音的阈值（噪声底之上）。比退出阈值高，形成迟滞
    static let enterThresholdDB: Float = 12
    /// 退出语音的阈值
    static let exitThresholdDB: Float = 7
    /// 短于这个时长的语音段丢弃（咳一声、关门声）
    static let minSpeechDuration: TimeInterval = 0.12
    /// 相邻语音段之间小于这个时长的静音被桥接（句中的换气）
    static let bridgeSilence: TimeInterval = 0.10

    // MARK: - 语音段检测

    static func speechSegments(from envelope: AudioEnvelope) -> [SpeechSegment] {
        let decibels = envelope.decibels
        guard decibels.count >= 5 else { return [] }

        let sorted = decibels.sorted()
        func percentile(_ fraction: Double) -> Float {
            sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let floor = min(percentile(noiseFloorPercentile),
                        percentile(0.50) - medianFallbackMarginDB)

        // 带迟滞的状态机：进入用高阈值，退出用低阈值，
        // 一个音节内部的能量起伏不会把一句话切碎
        var segments: [SpeechSegment] = []
        var inSpeech = false
        var speechStart = 0.0
        for (index, value) in decibels.enumerated() {
            let time = Double(index) * AudioEnvelope.hopDuration
            let threshold = inSpeech ? floor + exitThresholdDB : floor + enterThresholdDB
            if !inSpeech {
                if value >= threshold {
                    inSpeech = true
                    speechStart = time
                }
            } else if value < threshold {
                inSpeech = false
                segments.append(SpeechSegment(start: speechStart, end: time))
            }
        }
        if inSpeech {
            segments.append(SpeechSegment(start: speechStart, end: envelope.totalDuration))
        }

        // 桥接短静音（句中换气），再丢掉太短的误报
        var bridged: [SpeechSegment] = []
        for segment in segments {
            if let previous = bridged.last, segment.start - previous.end < bridgeSilence {
                bridged[bridged.count - 1] = SpeechSegment(start: previous.start, end: segment.end)
            } else {
                bridged.append(segment)
            }
        }
        return bridged.filter { $0.end - $0.start >= minSpeechDuration }
    }

    // MARK: - 边界吸附

    /// 返回吸附后的字幕段与调整条数
    static func snap(_ segments: [SubtitleSegment],
                     speech: [SpeechSegment],
                     totalDuration: TimeInterval) -> (segments: [SubtitleSegment], adjusted: Int) {
        guard !speech.isEmpty, !segments.isEmpty else { return (segments, 0) }

        var result: [SubtitleSegment] = []
        var adjusted = 0

        for (index, segment) in segments.enumerated() {
            var newStart = segment.start
            var newEnd = segment.end

            if let onset = nearestEdge(of: speech, edge: \.start, to: segment.start),
               abs(onset - segment.start) >= minAdjustment {
                newStart = onset
            }
            if let offset = nearestEdge(of: speech, edge: \.end, to: segment.end),
               abs(offset - segment.end) >= minAdjustment {
                newEnd = offset
            }

            // 吸附后太短说明两个边界被拖到了同一段语音上，放弃这组的调整
            guard newEnd - newStart >= 0.05 else {
                result.append(segment)
                continue
            }

            // 不越界、不与邻段交叉
            let lower = index > 0 ? segments[index - 1].end + 0.02 : 0
            let upper = index + 1 < segments.count
                ? segments[index + 1].start - 0.02
                : max(totalDuration, segment.end)
            newStart = min(max(newStart, lower), newEnd - 0.05)
            newEnd = max(min(newEnd, upper), newStart + 0.05)

            if newStart != segment.start || newEnd != segment.end { adjusted += 1 }
            result.append(SubtitleSegment(id: segment.id,
                                          start: newStart,
                                          end: newEnd,
                                          text: segment.text,
                                          confidence: segment.confidence,
                                          isSuspectedWatermark: segment.isSuspectedWatermark))
        }
        return (result, adjusted)
    }

    private static func nearestEdge(of speech: [SpeechSegment],
                                    edge: KeyPath<SpeechSegment, TimeInterval>,
                                    to target: TimeInterval) -> TimeInterval? {
        var best: TimeInterval?
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        for segment in speech {
            let candidate = segment[keyPath: edge]
            let distance = abs(candidate - target)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return bestDistance <= maxSnap ? best : nil
    }
}
