import Foundation
import Darwin
import AVFoundation
import CoreVideo
import CoreMedia

/// FFmpeg 可执行文件的位置。
///
/// 走子进程而不是链接 libav*：不需要处理 ABI 和构建系统，也不会因为库版本
/// 冲突把整个 app 带崩。代价是每次解码要起一个进程，但视频提取本来就是长任务，
/// 启动开销可以忽略。
enum FFmpegLocator {

    nonisolated(unsafe) private static var cached: URL??

    static var binary: URL? {
        if let cached { return cached }
        let found = locate()
        cached = found
        return found
    }

    private static func locate() -> URL? {
        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["HS_FFMPEG_PATH"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }

        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("ffmpeg"))
            candidates.append(directory.appendingPathComponent("../Resources/ffmpeg"))
            candidates.append(directory.appendingPathComponent("../../Vendor/ffmpeg/ffmpeg"))
            candidates.append(directory.appendingPathComponent("../../../Vendor/ffmpeg/ffmpeg"))
        }
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("ffmpeg"))
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { binary != nil }
}

/// FFmpeg 探测出来的元信息
struct FFmpegMediaInfo {
    var width: Int
    var height: Int
    var duration: Double
    var codec: String
}

/// 用 FFmpeg 解码视频帧。
///
/// 覆盖 AVFoundation 解不了的格式：MKV / AVI / FLV / 10-bit H.264 / AV1 / VP9 / WMV …
/// 帧率过滤和缩放都交给 FFmpeg 的滤镜做，读端只需要按固定字节数切帧。
final class FFmpegProcess {

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let frameBytes: Int
    private let buffer: UnsafeMutableRawPointer
    private var pixelBuffer: CVPixelBuffer?
    private var frameIndex = 0
    private let fps: Double
    private let lock = NSLock()
    private var stderrText = ""
    private var stopped = false

    let width: Int
    let height: Int

    // MARK: - 探测

    /// 跑一次 `ffmpeg -i` 解析元信息。ffmpeg 没有输出目标时会以非零退出，
    /// 但流信息已经打到 stderr 了，这正是我们要的。
    static func probe(url: URL) -> FFmpegMediaInfo? {
        guard let binary = FFmpegLocator.binary else { return nil }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-nostdin", "-hide_banner", "-i", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 看门狗：病态文件可能让 ffmpeg 卡住，30 秒后强杀，读端随 EOF 返回
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Duration: 00:02:04.98, start: ...
        var duration: Double = 0
        if let match = text.firstMatch(of: #/Duration:\s*(\d+):(\d+):(\d+)\.(\d+)/#) {
            let hours = Double(match.1) ?? 0
            let minutes = Double(match.2) ?? 0
            let seconds = Double(match.3) ?? 0
            let fraction = Double("0." + (match.4.isEmpty ? "0" : String(match.4))) ?? 0
            duration = hours * 3600 + minutes * 60 + seconds + fraction
        }

        // Stream #0:0: Video: h264 (High 10), yuv420p10le, 1920x1080 ...
        // 跳过封面流（attached pic）：有些工具会把封面缩略图排在主视频前面，
        // 按它取分辨率会把真实画面按封面尺寸缩放。
        let stream = text.matches(of: #/Stream #\d+:\d+.*?: Video: ([^,]+)(?:[^\n]*?), (\d+)x(\d+)/#)
            .first { !$0.output.0.lowercased().contains("attached pic") }
        guard let stream else {
            return nil
        }
        let codec = String(stream.1).trimmingCharacters(in: .whitespaces)
        guard let width = Int(stream.2), let height = Int(stream.3) else { return nil }

        return FFmpegMediaInfo(width: width, height: height, duration: duration, codec: codec)
    }

    // MARK: - 解码

    /// - Parameters:
    ///   - fps: 输出帧率，交给 ffmpeg 的 fps 滤镜做均匀采样
    ///   - maxLongSide: 长边上限，避免 4K 源一次占几十 MB
    init?(url: URL, fps: Double, maxLongSide: Int = 1920) {
        guard let binary = FFmpegLocator.binary,
              let info = Self.probe(url: url), info.width > 0, info.height > 0 else { return nil }

        let longSide = max(info.width, info.height)
        let scale = longSide > maxLongSide ? Double(maxLongSide) / Double(longSide) : 1
        // 保持偶数宽高，否则某些像素格式会出问题
        let targetWidth = max(2, Int((Double(info.width) * scale).rounded(.down)) / 2 * 2)
        let targetHeight = max(2, Int((Double(info.height) * scale).rounded(.down)) / 2 * 2)

        self.width = targetWidth
        self.height = targetHeight
        self.frameBytes = targetWidth * targetHeight * 4
        self.fps = max(0.5, fps)

        process.executableURL = binary
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", url.path,
            "-vf", "fps=\(fps),scale=\(targetWidth):\(targetHeight)",
            "-pix_fmt", "bgra",
            "-f", "rawvideo",
            "pipe:1"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        guard let storage = UnsafeMutableRawPointer.allocate(byteCount: frameBytes,
                                                             alignment: 64) as UnsafeMutableRawPointer? else {
            return nil
        }
        buffer = storage

        // 内存所有权交给 pixelBuffer：在释放回调里 deallocate。
        // 以前由 FFmpegProcess 自己管理但 deinit 里从不释放，每个实例泄漏约一帧的内存；
        // 交给回调还能覆盖「pixelBuffer 比 FFmpegProcess 活得久」的情况。
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            targetWidth, targetHeight,
            kCVPixelFormatType_32BGRA,
            storage,
            targetWidth * 4,
            { refCon, _ in refCon?.deallocate() },
            storage,
            nil,
            &pb
        )
        guard status == kCVReturnSuccess, let created = pb else {
            storage.deallocate()
            return nil
        }
        pixelBuffer = created

        // 持续排空 stderr，否则管道写满会把 ffmpeg 卡住
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrText += String(data: data, encoding: .utf8) ?? ""
            self.lock.unlock()
        }

        do {
            try process.run()
        } catch {
            // storage 已归 pixelBuffer 的释放回调管，这里不能再 deallocate
            return nil
        }
    }

    deinit {
        cancel()
    }

    /// 读下一帧。返回 nil 表示结束或出错。
    ///
    /// 直接用 POSIX read 读进预分配的缓冲区，不经过 Data。
    /// 用 `FileHandle.read(upToCount:)` 每帧会产出一块 8 MB 的 Data，
    /// 在后台线程没有 autorelease pool 时会一路堆积（实测 12 秒片子涨到 480 MB）。
    func nextFrame() -> (buffer: CVPixelBuffer, time: Double)? {
        guard !stopped, let pixelBuffer else { return nil }

        let descriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        var filled = 0
        while filled < frameBytes {
            let count = read(descriptor, buffer + filled, frameBytes - filled)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }   // EOF
            filled += count
        }

        let time = Double(frameIndex) / fps
        frameIndex += 1
        return (pixelBuffer, time)
    }

    func cancel() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // 不关闭 stdout：另一线程可能正阻塞在 read() 上，先关 fd 有读到
        // 复用描述符的风险。直接 terminate 让写端关闭，阻塞中的 read 以 EOF 返回。
        if process.isRunning {
            process.terminate()
        }
    }

    var errorDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
