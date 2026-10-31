import Foundation

struct AggregationConfig {
    /// 相邻两帧文本相似度阈值，高于此值视为同一句字幕
    var similarityThreshold: Double = 0.80
    /// 允许的最大帧间空隙（秒），超过就断句（文本完全相同时不受此限）
    var maxGap: Double = 0.60
    /// 短于这个时长的片段视为误检
    var minDuration: Double = 0.20
    /// 输出字幕的最短时长
    var minOutputDuration: Double = 0.50
    /// 某段文本累计占据全片比例超过该值，判定为水印 / 台标
    var watermarkRatio: Double = 0.35
    /// 只有长度不超过该值的重复文本才会被判为水印（避免误伤歌词）
    var watermarkMaxLength: Int = 16
}

/// 把逐帧 OCR 结果聚合成带时间轴的字幕。
///
/// 分两层：
/// 1. 每条字幕行（锚点）各自聚合出时间轴；
/// 2. 跨锚点合并 —— 同一时刻有几行字幕，就输出几行文本。
///
/// 几个关键设计，都是实测踩出来的：
/// - 文本用**多帧投票**决定，不是逐帧比置信度。同一句里「行」被读成「衍」时，
///   单帧置信度差异只有 0.01 量级，谁高谁低是噪声；票数才是信号。
/// - 文本完全相同时**不看时间间隔**。画面静止时感知哈希不变、不产生新观测，
///   用间隔切断会把一句话拆成好几段。
/// - 「识别为空」只标记**候选结束点**，不立刻收尾，否则每段只剩首帧那么长。
/// - 比较用去掉首尾标点的 key，避免 OCR 多吐的 "/" "-" 影响长度判断。
enum SubtitleAggregator {

    private struct Vote {
        var count: Int
        var bestScore: Double
    }

    /// 聚合过程中的「当前这一句」：存的是每一帧读法的票数
    private struct Draft {
        var start: TimeInterval
        var end: TimeInterval
        var confidence: Double
        var votes: [String: Vote]

        var winner: (text: String, score: Double) { SubtitleAggregator.winner(of: votes) }
    }

    /// 比较用的规范化：去掉首尾标点
    private static let edgePunctuation = CharacterSet(charactersIn:
        " \t/\\-–—_.,;:!?~`'\"()[]{}<>|+*=&#@$%^，。、；：！？「」『』（）《》〈〉…·")

    private static func comparisonKey(_ text: String) -> String {
        text.trimmingCharacters(in: edgePunctuation)
    }

    /// 多数票胜出；票数相同看置信度，再相同看有效长度。
    private static func winner(of votes: [String: Vote]) -> (text: String, score: Double) {
        var bestText = ""
        var bestCount = -1
        var bestScore: Double = 0
        var bestLength = -1

        for (text, vote) in votes {
            let length = comparisonKey(text).count
            let better = vote.count > bestCount
                || (vote.count == bestCount && vote.bestScore > bestScore)
                || (vote.count == bestCount && vote.bestScore == bestScore && length > bestLength)
            if better {
                bestText = text
                bestCount = vote.count
                bestScore = vote.bestScore
                bestLength = length
            }
        }
        return (bestText, bestScore)
    }

    // MARK: - 对外入口

    static func aggregate(_ observations: [OCRObservation],
                          anchors: [SubtitleAnchor],
                          totalDuration: TimeInterval,
                          config: AggregationConfig = AggregationConfig()) -> [SubtitleSegment] {

        guard !anchors.isEmpty else { return [] }

        var grouped: [UUID: [OCRObservation]] = [:]
        for observation in observations {
            grouped[observation.anchorID, default: []].append(observation)
        }

        // 按画面从上到下的顺序排列，保证多行字幕的输出顺序稳定
        let ordered = anchors.sorted { $0.centerY < $1.centerY }
        var perAnchor: [(anchor: SubtitleAnchor, segments: [SubtitleSegment])] = []
        for anchor in ordered {
            let stream = grouped[anchor.id] ?? []
            perAnchor.append((anchor, aggregateStream(stream, config: config)))
        }

        var merged = mergeAcrossAnchors(perAnchor, config: config)
        merged = sanitize(merged, config: config)
        markWatermarks(&merged, totalDuration: totalDuration, config: config)
        return merged
    }

    // MARK: - 单条字幕行的聚合

    private static func aggregateStream(_ observations: [OCRObservation],
                                        config: AggregationConfig) -> [SubtitleSegment] {
        let ordered = observations
            .map { OCRObservation(anchorID: $0.anchorID,
                                  time: $0.time,
                                  frameEnd: $0.frameEnd,
                                  text: normalize($0.text),
                                  confidence: $0.confidence) }
            .sorted { $0.time < $1.time }

        var segments: [SubtitleSegment] = []
        var current: Draft?

        func flush(until endTime: TimeInterval? = nil) {
            guard var draft = current else { return }
            if let endTime {
                draft.end = max(draft.end, endTime)
            }
            let result = draft.winner
            segments.append(SubtitleSegment(start: draft.start,
                                            end: draft.end,
                                            text: result.text,
                                            confidence: max(draft.confidence, result.score)))
            current = nil
        }

        func startDraft(_ observation: OCRObservation) -> Draft {
            Draft(start: observation.time,
                  end: observation.frameEnd,
                  confidence: observation.confidence,
                  votes: [observation.text: Vote(count: 1, bestScore: observation.confidence)])
        }

        func castVote(_ text: String, score: Double, into draft: inout Draft) {
            var vote = draft.votes[text] ?? Vote(count: 0, bestScore: 0)
            vote.count += 1
            vote.bestScore = max(vote.bestScore, score)
            draft.votes[text] = vote
        }

        // 「识别为空」只标记候选结束点，不立刻收尾：
        // 画面静止时一帧空之后可能很久都没有新观测，直接收尾会让每段只剩首帧那么长。
        var pendingEnd: TimeInterval?

        for observation in ordered {
            if observation.isEmpty {
                if pendingEnd == nil { pendingEnd = observation.time }
                continue
            }

            guard var draft = current else {
                pendingEnd = nil
                current = startDraft(observation)
                continue
            }

            // 中间出现过空帧：紧接着又读回同样的文本，说明只是漏识别了一帧
            if let endAt = pendingEnd {
                let resumeGap = observation.time - endAt
                if observation.text == draft.winner.text && resumeGap <= 1.0 {
                    draft.end = max(draft.end, observation.frameEnd)
                    draft.confidence = max(draft.confidence, observation.confidence)
                    castVote(observation.text, score: observation.confidence, into: &draft)
                    pendingEnd = nil
                    current = draft
                    continue
                }
                // 真的换句了：在候选结束点收尾
                flush(until: endAt)
                pendingEnd = nil
                current = startDraft(observation)
                continue
            }

            let gap = observation.time - draft.end
            let similarity = self.similarity(draft.winner.text, observation.text)
            // 文本完全相同时不看时间间隔
            let identical = observation.text == draft.winner.text

            if similarity >= config.similarityThreshold && (identical || gap <= config.maxGap) {
                draft.end = max(draft.end, observation.frameEnd)
                draft.confidence = max(draft.confidence, observation.confidence)
                castVote(observation.text, score: observation.confidence, into: &draft)
                current = draft
            } else {
                // 旧句的结尾没有空帧观测：句与句首尾相接（换句帧直接读到新文本），
                // 或者消失帧被误读成了别的文字。用新观测的时间闭段——旧字幕
                // 最多活到新内容出现的这一帧，否则段尾会停在最后一次投票帧。
                flush(until: observation.time)
                current = startDraft(observation)
            }
        }

        if let endAt = pendingEnd { flush(until: endAt) }
        flush()

        return mergeAdjacent(segments, config: config)
    }

    // MARK: - 跨锚点合并

    /// 时间轴扫描：在每个时间片里收集各锚点当前显示的文本，按行拼成一条字幕。
    private static func mergeAcrossAnchors(_ perAnchor: [(anchor: SubtitleAnchor, segments: [SubtitleSegment])],
                                           config: AggregationConfig) -> [SubtitleSegment] {
        let active = perAnchor.filter { !$0.segments.isEmpty }
        guard !active.isEmpty else { return [] }

        var boundaries = Set<TimeInterval>()
        for entry in active {
            for segment in entry.segments {
                boundaries.insert(segment.start)
                boundaries.insert(segment.end)
            }
        }
        let times = boundaries.sorted()
        guard times.count >= 2 else { return [] }

        var result: [SubtitleSegment] = []
        var current: SubtitleSegment?

        for index in 0..<(times.count - 1) {
            let start = times[index]
            let end = times[index + 1]
            guard end > start else { continue }
            let probe = (start + end) / 2

            var lines: [String] = []
            var confidence: Double = 0
            for entry in active {
                if let segment = entry.segments.first(where: { $0.contains(probe) }), !segment.isBlank {
                    lines.append(segment.text)
                    confidence = max(confidence, segment.confidence)
                }
            }

            let text = lines.joined(separator: "\n")
            if text.isEmpty {
                if let finished = current { result.append(finished) }
                current = nil
                continue
            }

            if var running = current, running.text == text {
                running.end = end
                running.confidence = max(running.confidence, confidence)
                current = running
            } else {
                if let finished = current { result.append(finished) }
                current = SubtitleSegment(start: start, end: end, text: text, confidence: confidence)
            }
        }

        if let finished = current { result.append(finished) }
        return absorbSubsetFragments(result)
    }

    /// 吸收尾部碎片：如果某一段的行是前一段的子集且紧挨着，就并进前一段。
    /// 典型情况是双语字幕里其中一行先一步漏识别，导致最后零点几秒只剩一行。
    private static func absorbSubsetFragments(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        guard segments.count > 1 else { return segments }
        var result: [SubtitleSegment] = [segments[0]]

        for segment in segments.dropFirst() {
            guard var previous = result.last else { continue }
            let gap = segment.start - previous.end
            let previousLines = Set(previous.text.components(separatedBy: "\n"))
            let currentLines = Set(segment.text.components(separatedBy: "\n"))

            if gap <= 0.35, currentLines.isSubset(of: previousLines) {
                previous.end = max(previous.end, segment.end)
                result[result.count - 1] = previous
            } else {
                result.append(segment)
            }
        }
        return result
    }

    // MARK: - 文本规范化

    static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 相似度

    /// 归一化编辑距离。对中文按 Character 计算，避免 UTF-16 代理对错位。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let lhs = Array(a)
        let rhs = Array(b)
        if lhs.isEmpty || rhs.isEmpty { return 0 }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,
                                 current[j - 1] + 1,
                                 previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }

        let distance = Double(previous[rhs.count])
        return 1 - distance / Double(max(lhs.count, rhs.count))
    }

    // MARK: - 后处理

    private static func mergeAdjacent(_ segments: [SubtitleSegment],
                                      config: AggregationConfig) -> [SubtitleSegment] {
        guard !segments.isEmpty else { return [] }
        var result: [SubtitleSegment] = [segments[0]]

        for segment in segments.dropFirst() {
            guard var last = result.last else { continue }
            let gap = segment.start - last.end
            if last.text == segment.text && gap <= config.maxGap {
                last.end = max(last.end, segment.end)
                last.confidence = max(last.confidence, segment.confidence)
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func sanitize(_ segments: [SubtitleSegment],
                                 config: AggregationConfig) -> [SubtitleSegment] {
        var cleaned = segments.filter { !$0.isBlank && $0.duration >= config.minDuration }

        for index in cleaned.indices {
            var end = cleaned[index].end
            if end - cleaned[index].start < config.minOutputDuration {
                end = cleaned[index].start + config.minOutputDuration
            }
            // 不要和下一句重叠。以前给的最短时长下限（start + 0.1）会顶穿紧挨着的
            // 下一句起点，输出互相重叠的两条字幕；宁可短也不能越过下一句的起点。
            if index + 1 < cleaned.count, end > cleaned[index + 1].start {
                end = max(cleaned[index].start + 0.01,
                          cleaned[index + 1].start - 0.01)
            }
            cleaned[index].end = end
        }
        return cleaned
    }

    private static func markWatermarks(_ segments: inout [SubtitleSegment],
                                       totalDuration: TimeInterval,
                                       config: AggregationConfig) {
        guard totalDuration > 0 else { return }

        var occupied: [String: TimeInterval] = [:]
        for segment in segments {
            occupied[segment.text, default: 0] += segment.duration
        }

        for index in segments.indices {
            guard let total = occupied[segments[index].text],
                  total >= totalDuration * config.watermarkRatio,
                  segments[index].text.count <= config.watermarkMaxLength else { continue }
            segments[index].isSuspectedWatermark = true
        }
    }
}
