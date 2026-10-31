import Foundation
import AVFoundation
import SwiftUI
import AppKit

/// 无界面命令行入口，用于批处理、自动化测试，以及在没有素材时生成合成测试视频。
///
///   HardSubExtractor --make-sample out.mp4
///   HardSubExtractor --extract input.mp4 output.srt [--roi 0.72,0.98] [--interval 0.1]
enum CommandLineRunner {

    static func runIfNeeded() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }

        switch args[1] {
        case "--make-sample":
            let output = args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : "sample.mp4"
            let style: SampleVideoGenerator.Style = args.contains("--tiny") ? .tiny
                : (args.contains("--faint") ? .faint
                : (args.contains("--bilingual") ? .bilingual
                : (args.contains("--hard") ? .hard : .clean)))
            let duration = parseValue(args, flag: "--duration") ?? 12.0
            runBlocking {
                do {
                    let url = URL(fileURLWithPath: output)
                    let lines: [SampleVideoGenerator.Line]
                    if args.contains("--dense") {
                        lines = SampleVideoGenerator.denseLines(duration: duration)
                    } else if style == .bilingual {
                        lines = SampleVideoGenerator.bilingualLines
                    } else {
                        lines = SampleVideoGenerator.defaultLines
                    }
                    try await SampleVideoGenerator.generate(to: url, lines: lines,
                                                             style: style, duration: duration)
                    print("已生成测试视频：\(url.path)")
                    print("风格：\(style.label)")
                    print("内嵌字幕：")
                    for line in lines {
                        print(String(format: "  %6.2f - %6.2f  %@", line.start, line.end, line.text))
                    }
                } catch {
                    print("生成失败：\(error.localizedDescription)")
                }
            }
            return true

        case "--extract":
            guard args.count >= 3 else {
                print("用法：HardSubExtractor --extract <视频路径> [输出.srt] [--roi 0.72,0.98] [--interval 0.1]")
                return true
            }
            let inputPath = args[2]
            let outputPath = args.count >= 4 && !args[3].hasPrefix("--") ? args[3] : nil
            let roi = parseROI(args) ?? ExtractionConfig().roi
            // --fps 是新参数；--interval（秒）保留兼容，换算成帧率
            let fps = parseValue(args, flag: "--fps")
                ?? parseValue(args, flag: "--interval").map { $0 > 0 ? 1 / $0 : 10 }
                ?? 10
            let engineName = parseString(args, flag: "--engine") ?? "vision"

            runBlocking {
                await extract(path: inputPath, outputPath: outputPath,
                              roi: roi, fps: fps, engineName: engineName,
                              upscaleOverride: parseValue(args, flag: "--upscale").map { CGFloat($0) },
                              voteFrames: Int(parseValue(args, flag: "--votes") ?? 3),
                              verbose: args.contains("--verbose"))
            }
            return true

        case "--probe":
            guard args.count >= 3 else {
                print("用法：HardSubExtractor --probe <视频> [秒] [--engine vision|paddle] [--roi 0.72,0.98]")
                return true
            }
            let engineName = parseString(args, flag: "--engine") ?? "paddle"
            let time = args.count >= 4 && !args[3].hasPrefix("--") ? (Double(args[3]) ?? 1.0) : 1.0
            let roi = parseROI(args) ?? ExtractionConfig().roi
            runBlocking {
                await probe(path: args[2], time: time, roi: roi, engineName: engineName)
            }
            return true

        case "--selftest":
            guard args.count >= 3 else {
                print("用法：HardSubExtractor --selftest <视频> [--engine vision|paddle]")
                return true
            }
            let engineName = parseString(args, flag: "--engine") ?? "vision"
            runBlocking {
                await selfTest(path: args[2], engineName: engineName)
            }
            return true

        case "--frame":
            guard args.count >= 4 else {
                print("用法：HardSubExtractor --frame <视频> <秒> [输出.png]")
                return true
            }
            let seconds = Double(args[3]) ?? 0
            let output = args.count >= 5 ? args[4] : "/tmp/frame.png"
            let started = Date()
            if let image = FFmpegFrameExtractor.frame(url: URL(fileURLWithPath: args[2]), time: seconds) {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: output))
                    print(String(format: "已抽帧 %.2fs → %@  %d×%d  耗时 %.0fms",
                                 seconds, output, image.width, image.height,
                                 Date().timeIntervalSince(started) * 1000))
                }
            } else {
                print("抽帧失败")
            }
            return true

        case "--render-ui":
            let output = args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : "ui.png"
            let variant = parseString(args, flag: "--variant") ?? "loaded"
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                renderUI(to: output, variant: variant)
            }
            return true

        case "--help", "-h":
            print("""
            HardSubExtractor — 硬字幕提取

              --make-sample <输出.mp4>              生成带硬字幕的合成测试视频
              --extract <视频> [输出.srt] [选项]     提取字幕并写出 SRT

              选项：
                --roi <top,bottom>    字幕区域纵向范围，默认 0.58,1.00
                --interval <秒>       抽帧最小间隔，默认 0.10

              不带参数启动则进入图形界面。
            """)
            return true

        default:
            return false
        }
    }

    // MARK: - 提取

    private static func extract(path: String,
                                outputPath: String?,
                                roi: CGRect,
                                fps: Double,
                                engineName: String,
                                upscaleOverride: CGFloat?,
                                voteFrames: Int,
                                verbose: Bool) async {
        // 进度回调是 @Sendable，用带锁的小盒子做节流，避免捕获可变局部变量
        final class AnalyzeThrottle: @unchecked Sendable {
            private var last = -1
            private let lock = NSLock()
            func shouldReport(_ value: Double) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                let bucket = Int(value * 4)
                guard bucket != last else { return false }
                last = bucket
                return true
            }
        }
        let analyzeThrottle = AnalyzeThrottle()
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("找不到文件：\(url.path)")
            return
        }

        let recognizer: any SubtitleRecognizer
        if engineName == "paddle" {
            let paddle = PaddleOCRRecognizer()
            guard paddle.isAvailable else {
                print("PaddleOCR 不可用：\(paddle.unavailableReason ?? "未知原因")")
                return
            }
            recognizer = paddle
            print("引擎：\(paddle.displayName) · \(paddle.statusDescription)")
        } else {
            recognizer = VisionRecognizer(languages: ["zh-Hans", "en-US"])
            print("引擎：Apple Vision")
        }

        // 先体检，把「解不了」和「解得了但没字幕」区分开
        let probe = await VideoProbe.probe(url: url)
        if let problem = probe.problem {
            print("无法处理这个视频：")
            print(problem)
            return
        }
        print(String(format: "视频：%@ %@ %.0f×%.0f %.1fs  解码器=%@",
                     url.lastPathComponent, probe.codec,
                     probe.naturalSize.width, probe.naturalSize.height, probe.duration,
                     probe.decoder.displayName))
        if let note = probe.note { print("  \(note)") }

        let started = Date()
        print("开始提取：\(url.lastPathComponent)")
        print(String(format: "搜索范围：y %.2f–%.2f，采样 %.0f fps",
                     roi.origin.y, roi.origin.y + roi.size.height, fps))

        // 默认：Paddle 不放大（rec 内部会缩到 48 高），Vision 放大 1.6 倍
        let upscale: CGFloat = upscaleOverride ?? (engineName == "paddle" ? 1.0 : 1.6)

        // 第一阶段：自动找出字幕行
        var detection = AnchorDetectionConfig(searchROI: roi)
        detection.decoder = probe.decoder
        let detected = (try? await AnchorDetector.detect(url: url,
                                                         config: detection,
                                                         recognizer: recognizer) { value, text in
            if value < 1, analyzeThrottle.shouldReport(value) {
                print(String(format: "  [分析] %3.0f%%  %@", value * 100, text))
            }
        }) ?? AnchorDetector.Result(anchors: [], scannedSeconds: 0, samples: 0)

        print("扫描 \(String(format: "%.0f", detected.scannedSeconds)) 秒 / \(detected.samples) 帧，找到 \(detected.anchors.count) 行字幕")
        for anchor in detected.anchors {
            print(String(format: "  行 y=%.3f 高=%.3f 宽=%.3f %@ %@",
                         anchor.rect.midY, anchor.rect.height, anchor.rect.width,
                         anchor.language.displayName,
                         anchor.isPrimary ? "(主)" : ""))
        }
        if detected.anchors.isEmpty {
            print("  没找到固定字幕行，退回整块区域识别")
        }

        // 第二阶段：按锚点提取
        let config = ExtractionConfig(roi: roi,
                                      anchors: detected.anchors,
                                      fps: fps,
                                      hashThreshold: 4,
                                      upscale: upscale,
                                      decoder: probe.decoder,
                                      totalDuration: probe.duration,
                                      voteFrames: voteFrames)

        var segments: [SubtitleSegment] = []
        var lastReported = -1

        for await event in ExtractionEngine.run(url: url, config: config, recognizer: recognizer) {
            switch event {
            case .progress(let value, let text):
                let bucket = Int(value * 10)
                if bucket != lastReported && value < 1 {
                    lastReported = bucket
                    print(String(format: "  %3.0f%%  %@  [%@]",
                                 value * 100, text, MemoryProbe.describe()))
                }
            case .observation(let observation):
                if verbose {
                    print(String(format: "  [obs %.2f] %.3f  %@",
                                 observation.time, observation.confidence,
                                 observation.text.replacingOccurrences(of: "\n", with: "⏎")))
                }
            case .finished(let result, _, _):
                segments = result
            case .failed(let message):
                print("提取失败：\(message)")
                return
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "耗时 %.1fs，得到 %d 条字幕", elapsed, segments.count))

        let srt = SubtitleExporter.srt(segments)
        if let outputPath {
            let outputURL = URL(fileURLWithPath: outputPath)
            do {
                try srt.write(to: outputURL, atomically: true, encoding: .utf8)
                print("已写出：\(outputURL.path)")
            } catch {
                print("写出失败：\(error.localizedDescription)")
            }
        } else {
            print("---- SRT ----")
            print(srt)
        }
    }

    // MARK: - 参数解析

    private static func parseValue(_ args: [String], flag: String) -> Double? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return Double(args[index + 1])
    }

    private static func parseString(_ args: [String], flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func parseROI(_ args: [String]) -> CGRect? {        guard let index = args.firstIndex(of: "--roi"), index + 1 < args.count else { return nil }
        let parts = args[index + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, parts[0] < parts[1] else { return nil }
        return CGRect(x: 0.04, y: parts[0], width: 0.92, height: parts[1] - parts[0])
    }

    // MARK: - GUI 自检：走界面同一套 ViewModel

    /// 直接驱动 `ExtractorViewModel`，覆盖图形界面点击「开始提取」时执行的完整路径：
    /// 建 AVPlayer、装时间观察器、读时长、建识别器、消费事件流、填 segments。
    /// 区别只是不用鼠标点，也不弹保存面板。
    private static func selfTest(path: String, engineName: String) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("找不到文件：\(url.path)")
            return
        }

        let model = await MainActor.run { () -> ExtractorViewModel in
            let model = ExtractorViewModel()
            model.engine = engineName == "paddle" ? .paddle : .vision
            model.load(url: url)
            return model
        }

        // 时长和分辨率是异步读的，等一小会儿再读，否则只能看到初始值
        try? await Task.sleep(nanoseconds: 400_000_000)

        let loaded = await MainActor.run {
            (model.hasVideo, model.player != nil, model.statusText,
             model.videoDuration, model.videoResolution, model.videoAspect)
        }
        print("载入：hasVideo=\(loaded.0) player=\(loaded.1) "
              + String(format: "时长=%.2fs ", loaded.3)
              + "分辨率=\(loaded.4.isEmpty ? "未知" : loaded.4) "
              + String(format: "宽高比=%.3f", loaded.5))
        print("状态：\(loaded.2)")

        await MainActor.run { model.start() }

        let deadline = Date().addingTimeInterval(180)
        var lastProgress = -1.0
        while Date() < deadline {
            let state = await MainActor.run { (model.isRunning, model.progress, model.statusText) }
            if state.1 - lastProgress > 0.25 {
                lastProgress = state.1
                print(String(format: "  %3.0f%%  %@  [%@]",
                             state.1 * 100, state.2, MemoryProbe.describe()))
            }
            if !state.0 { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let result = await MainActor.run {
            (model.segments.count,
             model.exportableSegments.count,
             model.analyzedFrameCount,
             model.errorMessage,
             model.statusText,
             model.segments)
        }

        print("— 结果 —")
        print("segments=\(result.0)  可导出=\(result.1)  OCR帧数=\(result.2)")
        print("状态：\(result.4)")
        if let error = result.3 { print("错误：\(error)") }

        let srt = SubtitleExporter.srt(result.5)
        print("— SRT 前 12 行 —")
        for line in srt.components(separatedBy: .newlines).prefix(12) {
            print(line)
        }
    }

    // MARK: - 单帧探测（调参 / 排障）

    private static func probe(path: String, time: Double, roi: CGRect, engineName: String) async {
        let url = URL(fileURLWithPath: path)
        do {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let cgImage = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            print("取帧成功：\(cgImage.width)x\(cgImage.height) @ \(time)s")

            guard let buffer = makePixelBuffer(from: cgImage) else {
                print("无法转换成 CVPixelBuffer")
                return
            }

            let cropped = PixelToolkit.shared.cropBuffer(from: buffer, normalizedROI: roi, scale: 1.0)
            guard let cropped else {
                print("字幕区域裁剪失败")
                return
            }
            print("ROI 裁剪：\(CVPixelBufferGetWidth(cropped))x\(CVPixelBufferGetHeight(cropped))")

            let recognizer: any SubtitleRecognizer
            if engineName == "paddle" {
                let paddle = PaddleOCRRecognizer()
                paddle.debugLog = { print("  · \($0)") }
                print("可用性：\(paddle.isAvailable) · \(paddle.statusDescription)")
                if let reason = paddle.unavailableReason { print("原因：\(reason)") }
                recognizer = paddle
            } else {
                recognizer = VisionRecognizer(languages: ["zh-Hans", "en-US"])
            }

            do {
                let lines = try await recognizer.recognize(pixelBuffer: cropped)
                print("识别到 \(lines.count) 行：")
                for line in lines {
                    print(String(format: "  [%.2f] %@", line.confidence, line.text))
                }
            } catch {
                print("识别抛错：\(error.localizedDescription)")
            }
        } catch {
            print("探测失败：\(error.localizedDescription)")
        }
    }

    private static func makePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    // MARK: - 离屏渲染界面（用于布局自检 / 生成文档截图）

    /// variant: empty（未载入）/ loaded（已出结果）/ settings（参数面板展开）
    @MainActor
    private static func renderUI(to path: String, variant: String = "loaded") {
        let model = ExtractorViewModel()

        if variant != "empty" {
            model.videoURL = URL(fileURLWithPath: "/tmp/纪录片第三集.mp4")
            model.videoDuration = 1428
            model.videoResolution = "1920×1080"
            model.videoAspect = 16.0 / 9.0
            model.segments = [
                SubtitleSegment(start: 0.70, end: 2.70, text: "你好，世界", confidence: 0.98),
                SubtitleSegment(start: 3.20, end: 5.53, text: "这是一段测试字幕", confidence: 0.95),
                SubtitleSegment(start: 6.03, end: 8.27, text: "硬字幕提取测试", confidence: 0.93),
                SubtitleSegment(start: 8.90, end: 11.53, text: "最后一行字幕", confidence: 0.91),
                SubtitleSegment(start: 12.40, end: 15.20, text: "校对时可以逐句修改", confidence: 0.89),
                SubtitleSegment(start: 16.00, end: 18.10, text: "改完直接导出", confidence: 0.94)
            ]
            model.progress = 1
            model.statusText = "提取完成 · 共 6 条字幕"
            model.analyzedFrameCount = 128
            model.currentTime = 9.4
            // 空播放器只为了让播放区和字幕区域框进入渲染分支，
            // AVPlayerView 本身在 ImageRenderer 里会渲染成占位块。
            model.player = AVPlayer()
        }

        // HSplitView / AVPlayerView 都是 AppKit 支撑的，ImageRenderer 无法栅格化，
        // 所以快照用 HStack 复现同样的分栏比例，内容完全一致。
        // ScrollView 内容 ImageRenderer 也画不出来，参数区关闭内部滚动直接展开。
        let expanded = variant == "settings"
        let layout = HStack(spacing: 0) {
            PlayerPane(model: model)
                .frame(width: 800)
            Divider()
            VStack(spacing: 0) {
                SettingsPanel(model: model,
                              isExpanded: .constant(expanded),
                              scrollsWhenExpanded: false)
                Divider()
                SubtitleListView(model: model)
            }
            .background(Theme.surface)
            .frame(width: 479)
        }
        .frame(width: 1280, height: 820)
        .background(Theme.surface)

        let renderer = ImageRenderer(content: layout)
        renderer.scale = 2

        guard let cgImage = renderer.cgImage else {
            print("渲染失败：无法生成位图")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败：无法编码 PNG")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("已渲染界面：\(path)")
        } catch {
            print("写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 同步等待异步任务，同时保持主线程 RunLoop 运转

    private static func runBlocking(_ work: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await work()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}
