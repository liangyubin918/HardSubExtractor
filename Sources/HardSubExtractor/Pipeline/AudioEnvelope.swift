import Foundation

/// 音频能量包络：把音轨压成每 10ms 一个 dBFS 值，供语音活动检测用。
///
/// 音频参数（12kHz 单声道）参考 sushi 的做法；解码复用本项目「FFmpeg 走子进程」
/// 的惯例，流式读取边解边算——内存里只保留包络，2 小时片子 ≈ 72 万个 Float ≈ 2.9MB，
/// 而不是几百 MB 的 PCM。
struct AudioEnvelope {
    /// 每个能量点覆盖的时长
    static let hopDuration: TimeInterval = 0.01
    /// 静音的 dBFS 下限（低于一律按它算）
    static let silenceFloor: Float = -120

    /// dBFS 能量序列，hopDuration 一个点
    let decibels: [Float]

    var totalDuration: TimeInterval { Double(decibels.count) * Self.hopDuration }

    /// 解音轨并压成包络。没有音轨、ffmpeg 不可用或解码失败时返回 nil，
    /// 上层据此优雅跳过语音吸附。
    static func load(url: URL) async -> AudioEnvelope? {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.resume(returning: Self.decode(url: url))
            }
        }
    }

    private static func decode(url: URL) -> AudioEnvelope? {
        guard let ffmpeg = FFmpegLocator.binary else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        // -map 0:a:0? 是可选映射：没有音轨不报错，只是输出为空 → 包络为空 → nil
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
                             "-i", url.path, "-vn", "-map", "0:a:0?",
                             "-ar", "12000", "-ac", "1", "-acodec", "pcm_s16le",
                             "-f", "s16le", "pipe:1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let samplesPerHop = 120  // 12000 Hz × 0.01s
        var decibels: [Float] = []
        var sumOfSquares = 0.0
        var counted = 0

        func flushHop() {
            guard counted == samplesPerHop else { return }
            let rms = (sumOfSquares / Double(samplesPerHop)).squareRoot()
            let db = max(20 * log10(max(rms, 1e-6)), Double(Self.silenceFloor))
            decibels.append(Float(db))
            sumOfSquares = 0
            counted = 0
        }

        func consume(sample: Int16) {
            let normalized = Double(sample) / 32768.0
            sumOfSquares += normalized * normalized
            counted += 1
            flushHop()
        }

        let handle = pipe.fileHandleForReading
        var carry = Data()
        while true {
            if Task.isCancelled {
                process.terminate()
                return nil
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            carry.append(chunk)
            var offset = 0
            let bytes = [UInt8](carry)
            let usable = bytes.count - bytes.count % 2
            while offset + 1 < usable {
                let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                consume(sample: Int16(bitPattern: raw))
                offset += 2
            }
            carry = Data(bytes[usable...])
        }
        process.waitUntilExit()

        guard !decibels.isEmpty else { return nil }
        return AudioEnvelope(decibels: decibels)
    }
}
