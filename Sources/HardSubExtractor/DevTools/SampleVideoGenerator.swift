import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import AppKit

/// 生成带硬字幕的合成测试视频，用来在没有素材的情况下验证整条管线。
///
/// 两种风格：
///   clean —— 720p、48px、白字黑描边、深色衬底，模拟标准的影视字幕
///   hard  —— 480p、24px、半透明白字、无衬底且背景花哨，模拟小字号 + 低对比的恶劣片源
enum SampleVideoGenerator {

    struct Line {
        let start: Double
        let end: Double
        let text: String
    }

    enum Style {
        case clean
        case hard
        case tiny
        case faint
        case bilingual

        var width: Int {
            switch self {
            case .clean: return 1280
            case .hard: return 854
            case .tiny: return 640
            case .faint: return 854
            case .bilingual: return 1280
            }
        }

        var height: Int {
            switch self {
            case .clean: return 720
            case .hard: return 480
            case .tiny: return 360
            case .faint: return 480
            case .bilingual: return 720
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .clean: return 48
            case .hard: return 24
            case .tiny: return 17
            case .faint: return 26
            case .bilingual: return 40
            }
        }

        var strokeWidth: CGFloat { self == .clean ? -3.0 : (self == .faint ? -0.6 : -1.2) }
        var textAlpha: CGFloat { self == .clean ? 1.0 : (self == .faint ? 0.55 : 0.82) }
        var baselineRatio: CGFloat { self == .clean ? 0.10 : 0.08 }
        var hasBacking: Bool { self == .clean }
        var busyBackground: Bool { self != .clean }

        var label: String {
            switch self {
            case .clean: return "clean 720p / 48px / 有衬底"
            case .hard: return "hard 480p / 24px / 花背景无衬底"
            case .tiny: return "tiny 360p / 17px / 花背景无衬底"
            case .bilingual: return "bilingual 720p / 中英双语两行"
            case .faint: return "faint 480p / 26px / 半透明 0.55 细描边"
            }
        }
    }

    static let defaultLines: [Line] = [
        .init(start: 0.60, end: 2.60, text: "你好，世界"),
        .init(start: 3.20, end: 5.40, text: "这是一段测试字幕"),
        .init(start: 6.00, end: 8.20, text: "硬字幕提取测试"),
        .init(start: 8.80, end: 11.40, text: "最后一行字幕")
    ]

    /// 全片密集字幕，每 2.5 秒换一句，用来压测 OCR 与内存
    static func denseLines(duration: Double) -> [Line] {
        let samples = ["这是一段测试字幕", "硬字幕提取测试", "最后一行字幕",
                       "校对时可以逐句修改", "改完直接导出", "支持多语言识别",
                       "识别引擎可以切换", "字幕区域可以调整"]
        var result: [Line] = []
        var start = 0.4
        var index = 0
        while start + 2.2 < duration {
            result.append(Line(start: start, end: start + 2.2, text: samples[index % samples.count]))
            start += 2.5
            index += 1
        }
        return result
    }

    static func generate(to url: URL,
                         lines: [Line] = defaultLines,
                         style: Style = .clean,
                         fps: Int = 30,
                         duration: Double = 12.0) async throws {

        try? FileManager.default.removeItem(at: url)

        let width = style.width
        let height = style.height

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "SampleVideoGenerator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法添加视频输入"])
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "SampleVideoGenerator", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(duration * Double(fps))

        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw writer.error ?? NSError(domain: "SampleVideoGenerator", code: 3)
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw NSError(domain: "SampleVideoGenerator", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "像素缓冲池不可用"])
            }

            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer else {
                throw NSError(domain: "SampleVideoGenerator", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "创建像素缓冲失败"])
            }

            let time = Double(frameIndex) / Double(fps)
            draw(frameIndex: frameIndex, time: time, lines: lines, style: style,
                 into: buffer, width: width, height: height)

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? NSError(domain: "SampleVideoGenerator", code: 6)
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "SampleVideoGenerator", code: 7,
                                          userInfo: [NSLocalizedDescriptionKey: "写入未完成"])
        }
    }

    private static func draw(frameIndex: Int,
                             time: Double,
                             lines: [Line],
                             style: Style,
                             into buffer: CVPixelBuffer,
                             width: Int,
                             height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let ctx = CGContext(data: base,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)

        ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        if style.busyBackground {
            drawBusyBackground(ctx, frameIndex: frameIndex, width: w, height: h)
        } else {
            let period = 90
            let phase = CGFloat(frameIndex % period) / CGFloat(period)
            let barWidth = w * 0.12
            ctx.setFillColor(CGColor(red: 0.24, green: 0.30, blue: 0.42, alpha: 1))
            ctx.fill(CGRect(x: phase * (w - barWidth), y: h * 0.58, width: barWidth, height: h * 0.26))
        }

        if style.hasBacking {
            ctx.setFillColor(CGColor(red: 0.17, green: 0.20, blue: 0.28, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.45))
        }

        guard let line = lines.first(where: { time >= $0.start && time <= $0.end }) else { return }

        // 文本里的 \n 表示多行（双语字幕），第 0 行在最下面，往上排
        let rows = line.text.components(separatedBy: "\n")
        let baselineY = h * style.baselineRatio
        let gap = style.fontSize * 1.5

        for (index, text) in rows.enumerated() {
            let size = index == 0 ? style.fontSize : style.fontSize * 0.74
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: makeFont(size: size),
                kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: style.textAlpha),
                kCTStrokeColorAttributeName: CGColor(gray: 0, alpha: style.textAlpha),
                kCTStrokeWidthAttributeName: style.strokeWidth
            ]
            guard let attributed = CFAttributedStringCreate(kCFAllocatorDefault,
                                                            text as CFString,
                                                            attributes as CFDictionary) else { continue }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            ctx.textPosition = CGPoint(x: (w - bounds.width) / 2, y: baselineY + CGFloat(index) * gap)
            CTLineDraw(ctLine, ctx)
        }
    }

    /// 中英双语：同一时间两条锚点各一行
    static let bilingualLines: [Line] = [
        .init(start: 0.60, end: 2.60, text: "你好，世界\nHello, world"),
        .init(start: 3.20, end: 5.40, text: "这是一段测试字幕\nThis is a test subtitle"),
        .init(start: 6.00, end: 8.20, text: "硬字幕提取测试\nHard subtitle extraction"),
        .init(start: 8.80, end: 11.40, text: "最后一行字幕\nThe last line")
    ]

    /// 花哨背景：一堆随机色块 + 斜线，专门用来干扰文本检测和识别
    private static func drawBusyBackground(_ ctx: CGContext,
                                           frameIndex: Int,
                                           width: CGFloat,
                                           height: CGFloat) {
        var seed = UInt64(frameIndex / 12 + 1) &* 6364136223846793005 &+ 1442695040888963407
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFF) / 65535.0
        }

        for _ in 0..<26 {
            let x = next() * width
            let y = next() * height
            let blockWidth = 40 + next() * width * 0.35
            let blockHeight = 30 + next() * height * 0.3
            let shade = 0.18 + next() * 0.42
            ctx.setFillColor(CGColor(red: shade, green: shade * 0.95, blue: shade * 0.85, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: blockWidth, height: blockHeight))
        }

        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 0.35))
        ctx.setLineWidth(1.5)
        for index in 0..<14 {
            let offset = CGFloat(index) * 47
            ctx.move(to: CGPoint(x: offset - 200, y: 0))
            ctx.addLine(to: CGPoint(x: offset + 120, y: height))
        }
        ctx.strokePath()
    }

    private static func makeFont(size: CGFloat) -> CTFont {
        let candidates = ["PingFangSC-Semibold", "PingFangSC-Regular", "STHeitiSC-Medium", "Helvetica"]
        for name in candidates {
            if let font = NSFont(name: name, size: size) {
                return CTFontCreateWithName(font.fontName as CFString, size, nil)
            }
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
}
