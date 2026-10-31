import Foundation
import CoreGraphics
import ImageIO

/// 用 FFmpeg 抽一帧画面。
///
/// AVPlayer 走的是 AVFoundation，遇到它不支持的编码（MKV / 10-bit H.264 / AV1）就是黑屏。
/// 提取那边已经切到 FFmpeg 了，预览这边得跟上，否则用户看不到自己在框什么。
///
/// 这里不追求流畅播放，只求「拖到哪儿就能看到那一帧」。
enum FFmpegFrameExtractor {

    /// - Parameters:
    ///   - time: 目标时间（秒）
    ///   - maxLongSide: 预览图长边上限，避免 4K 源每帧几十 MB
    static func frame(url: URL, time: Double, maxLongSide: Int = 1280) -> CGImage? {
        guard let binary = FFmpegLocator.binary else { return nil }

        let process = Process()
        process.executableURL = binary
        // -ss 放在 -i 前面是快速定位；ffmpeg 会从关键帧解码到目标时间，精度够用
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.3f", max(0, time)),
            "-i", url.path,
            "-frames:v", "1",
            "-vf", "scale='if(gt(iw,ih),min(\(maxLongSide),iw),-2)':'if(gt(iw,ih),-2,min(\(maxLongSide),ih))'",
            "-f", "image2pipe",
            "-vcodec", "png",
            "pipe:1"
        ]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 看门狗：卡住的 ffmpeg 由它强杀，读端随 EOF 返回，避免预览永久挂起
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}
