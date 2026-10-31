import Foundation
import AVFoundation
import CoreGraphics

struct ExtractionConfig {
    /// 字幕搜索区域，归一化坐标（左上角原点）。
    /// 现在只在「没检测到锚点」时作为兜底使用。
    var roi = CGRect(x: 0.02, y: 0.58, width: 0.96, height: 0.42)
    /// 自动检测出的字幕行。为空则退化成用 roi 当一条锚点。
    var anchors: [SubtitleAnchor] = []
    /// 采样帧率。10 表示每秒判断 10 次，字幕切换足够
    var fps: Double = 10
    /// 感知哈希汉明距离阈值，小于等于它认为「这一行没变」
    var hashThreshold: Int = 4
    /// OCR 前对字幕行的放大倍数
    var upscale: CGFloat = 1.6
    /// 用哪套解码器
    var decoder: VideoDecoderKind = .auto
    /// 已知时长（秒）。为空则自己去问 AVFoundation，再不行问 FFmpeg。
    var totalDuration: Double?
    /// 某一行发生变化后，额外重复识别几帧用来投票。
    /// 逐行判重会把 OCR 次数压到最低，但也失去了多帧投票；
    /// 变化后补几帧能把准确率补回来，代价仍然远小于逐帧识别。
    var voteFrames: Int = 3

    var minInterval: Double { fps > 0 ? 1.0 / fps : 0.1 }

    /// 实际参与处理的行
    var effectiveAnchors: [SubtitleAnchor] {
        if !anchors.isEmpty { return anchors }
        return [SubtitleAnchor(rect: roi, language: .unknown, isPrimary: true, hits: 0)]
    }
}

enum ExtractionEvent {
    case progress(Double, String)
    case observation(OCRObservation)
    /// completed=false 表示用户手动停止，segments 是已识别的部分结果
    case finished([SubtitleSegment], completed: Bool, note: String)
    case failed(String)
}

enum ExtractionEngine {

    /// 时长决定进度条，必须能从任意容器拿到。
    /// AVFoundation 读不了的容器（MKV / AVI）交给 FFmpeg。
    private static func resolveDuration(url: URL, known: Double?) async -> Double {
        if let known, known > 0 { return known }
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds > 0 {
            return seconds
        }
        return FFmpegProcess.probe(url: url)?.duration ?? 0
    }

    static func run(url: URL,
                    config: ExtractionConfig,
                    recognizer: any SubtitleRecognizer) -> AsyncStream<ExtractionEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    // 时长要能从任意容器拿到：MKV / AVI 上 AVURLAsset 会直接抛
                    let duration = await Self.resolveDuration(url: url, known: config.totalDuration)
                    continuation.yield(.progress(0, "准备解码"))

                    let anchors = config.effectiveAnchors
                    // 拉取式读取：下游处理完一帧才解码下一帧，内存里始终只有一帧
                    let reader = try await VideoFrameReader(url: url,
                                                            minInterval: config.minInterval,
                                                            decoder: config.decoder)

                    // HS_PROFILE=1 时统计各阶段耗时，用来定位性能瓶颈
                    let profiling = ProcessInfo.processInfo.environment["HS_PROFILE"] == "1"
                    var tDecode = 0.0, tHash = 0.0, tCrop = 0.0, tOCR = 0.0
                    var ocrCount = 0

                    var observations: [OCRObservation] = []
                    var lastHashes: [UUID: [UInt64]] = [:]
                    var voteBudget: [UUID: Int] = [:]
                    var analyzedAnchors = 0
                    var totalFrames = 0
                    var lastFrameEnd: TimeInterval?

                    var mark = CFAbsoluteTimeGetCurrent()
                    while let frame = await reader.next() {
                        if profiling {
                            let now = CFAbsoluteTimeGetCurrent()
                            tDecode += now - mark
                            mark = now
                        }
                        if Task.isCancelled { break }
                        totalFrames += 1
                        lastFrameEnd = frame.frameEnd

                        // 进度按采样帧数上报，不能只跟着 OCR 走：
                        // 片子里没有字幕的段落不会触发 OCR，否则进度条会卡住不动。
                        if duration > 0, totalFrames % 10 == 0 {
                            let ratio = min(1, max(0, frame.time / duration))
                            continuation.yield(.progress(ratio,
                                                         "已识别 \(analyzedAnchors) 行 / 采样 \(totalFrames) 帧"))
                        }

                        for anchor in anchors {
                            // 先用感知哈希判断这一行有没有变，只有变了才做 OCR。
                            // 逐行判重是关键：一行变了不会连带另一行重新识别，
                            // 而且放宽搜索区域也不会因为背景变大而失去灵敏度。
                            let hash = PixelToolkit.shared.dHash(from: frame.pixelBuffer,
                                                                 normalizedROI: anchor.rect)
                            if profiling {
                                let now = CFAbsoluteTimeGetCurrent()
                                tHash += now - mark
                                mark = now
                            }
                            let changed: Bool
                            if let previous = lastHashes[anchor.id] {
                                changed = PixelToolkit.hamming(previous, hash) > config.hashThreshold
                            } else {
                                changed = true
                            }

                            if changed {
                                lastHashes[anchor.id] = hash
                                voteBudget[anchor.id] = max(0, config.voteFrames - 1)
                            } else {
                                let budget = voteBudget[anchor.id] ?? 0
                                guard budget > 0 else { continue }
                                voteBudget[anchor.id] = budget - 1
                            }

                            let cropRect = anchor.expanded(padding: 0.30)
                            guard let cropped = PixelToolkit.shared.cropBuffer(from: frame.pixelBuffer,
                                                                              normalizedROI: cropRect,
                                                                              scale: config.upscale) else {
                                continue
                            }
                            if profiling {
                                let now = CFAbsoluteTimeGetCurrent()
                                tCrop += now - mark
                                mark = now
                            }

                            analyzedAnchors += 1
                            ocrCount += 1
                            let lines = (try? await recognizer.recognize(pixelBuffer: cropped)) ?? []
                            if profiling {
                                let now = CFAbsoluteTimeGetCurrent()
                                tOCR += now - mark
                                mark = now
                            }
                            // 锚点内可能被识别成多行碎片，按从上到下的顺序拼回一行
                            let text = lines.map(\.text).joined(separator: " ")
                            let confidence = lines.map(\.confidence).max() ?? 0

                            let observation = OCRObservation(anchorID: anchor.id,
                                                             time: frame.time,
                                                             frameEnd: frame.frameEnd,
                                                             text: text,
                                                             confidence: confidence)
                            observations.append(observation)
                            continuation.yield(.observation(observation))
                        }
                    }

                    if profiling {
                        let line = String(format:
                            "[profile] 帧=%d OCR=%d 解码=%.2fs 哈希=%.2fs 裁剪=%.2fs 识别=%.2fs\n",
                            totalFrames, ocrCount, tDecode, tHash, tCrop, tOCR)
                        FileHandle.standardError.write(Data(line.utf8))
                    }

                    await reader.cancel()
                    if let failure = await reader.errorDescription(), !Task.isCancelled {
                        throw FrameSamplerError.readerFailed(failure)
                    }

                    // 收尾观测：给每条锚点补一个「最后一帧之后的空」观测，
                    // 让还开着的字幕草稿在最后一个采样点闭段。否则一直显示到片尾、
                    // 中间又没有新观测的字幕（静止画面上很常见），段尾会被截短到投票帧。
                    if let closingTime = lastFrameEnd {
                        for anchor in anchors {
                            observations.append(OCRObservation(anchorID: anchor.id,
                                                               time: closingTime,
                                                               frameEnd: closingTime,
                                                               text: "",
                                                               confidence: 0))
                        }
                    }

                    let segments = SubtitleAggregator.aggregate(observations,
                                                               anchors: anchors,
                                                               totalDuration: duration)
                    // 解码过程中出过错（文件局部损坏）但解出过帧：结果照常给，文案里提示
                    let warning = (await reader.hadDecodeErrors() && !segments.isEmpty)
                        ? "（源文件有损坏，结果可能不完整）" : ""

                    if Task.isCancelled {
                        // 手动停止：已识别的部分结果照常聚合交付，不再丢弃
                        let note = segments.isEmpty
                            ? "已停止，没有可保留的结果"
                            : "已手动停止，保留 \(segments.count) 条部分结果\(warning)"
                        continuation.yield(.finished(segments, completed: false, note: note))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.finished(segments, completed: true,
                                                 note: "完成，共 \(segments.count) 条字幕\(warning)"))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
