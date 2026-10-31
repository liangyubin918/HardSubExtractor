import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

struct SampledFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: TimeInterval
    let frameEnd: TimeInterval
}

enum FrameSamplerError: LocalizedError {
    case noVideoTrack
    case cannotAddOutput
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "这个文件里没有找到视频轨道"
        case .cannotAddOutput:
            return "无法为视频轨道创建解码输出"
        case .readerFailed(let message):
            return """
            解码中断：\(message)

            可能是文件中间有损坏，或者编码不受支持。用 HandBrake 转成 H.264 的 MP4 再试通常能解决。
            """
        }
    }
}

/// 用哪套解码器
enum VideoDecoderKind: String, Sendable {
    /// 优先 AVFoundation，不行再退到 FFmpeg
    case auto
    /// 强制 AVFoundation（硬件加速，最快）
    case avFoundation
    /// 强制 FFmpeg（兼容性最好，能解 MKV / 10-bit H.264 / AV1 等）
    case ffmpeg

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .avFoundation: return "AVFoundation"
        case .ffmpeg: return "FFmpeg"
        }
    }
}

/// 拉取式视频帧读取器：只有调用 next() 时才解码下一帧，绝不提前缓冲。
///
/// 这里曾经用 AsyncStream 推送帧，而 AsyncStream 默认是无界缓冲。
/// 解码速度远快于 OCR，更远快于图形界面的消费速度（消费者跑在 MainActor 上），
/// 于是帧在缓冲区里无限堆积 —— 一帧 1080p 的 BGRA 是 8 MB，几分钟就能吃掉几十 GB。
///
/// 改成拉取式之后，内存里始终只有一帧，下游多慢都不会涨。
///
/// 两条后端：AVFoundation（硬件解码，快）和 FFmpeg（兼容性，能解 AVFoundation 不支持的格式）。
actor VideoFrameReader {

    private enum Backend {
        case avFoundation(AVAssetReader, AVAssetReaderOutput)
        case ffmpeg(FFmpegProcess)
    }

    private let backend: Backend
    private let minInterval: TimeInterval
    private let fallbackFrameDuration: TimeInterval
    private var lastEmitted: TimeInterval = -.infinity
    private var exhausted = false
    private var failure: String?
    /// 是否至少解出过一帧。决定错误是「失败」还是「局部损坏的告警」。
    private var decodedAny = false
    /// 解码过程中出过错（文件局部损坏），结果可能不完整
    private var decodeErrors = false

    /// 实际用上的后端，供界面显示
    nonisolated(unsafe) private(set) var usedDecoder: VideoDecoderKind = .auto

    init(url: URL, minInterval: Double, decoder: VideoDecoderKind = .auto) async throws {
        self.minInterval = minInterval

        if decoder != .ffmpeg {
            if let av = try? await Self.makeAVBackend(url: url, minInterval: minInterval) {
                backend = .avFoundation(av.reader, av.output)
                fallbackFrameDuration = av.frameDuration
                usedDecoder = .avFoundation
                return
            }
            if decoder == .avFoundation {
                throw FrameSamplerError.readerFailed("AVFoundation 打不开这个文件")
            }
        }

        guard let ff = FFmpegProcess(url: url, fps: max(0.5, 1.0 / minInterval)) else {
            throw FrameSamplerError.readerFailed("FFmpeg 也打不开这个文件")
        }
        backend = .ffmpeg(ff)
        fallbackFrameDuration = minInterval
        usedDecoder = .ffmpeg
    }

    private static func makeAVBackend(url: URL, minInterval: Double)
        async throws -> (reader: AVAssetReader, output: AVAssetReaderOutput, frameDuration: Double) {

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameSamplerError.noVideoTrack
        }
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let frameDuration = nominalFrameRate > 0 ? 1.0 / Double(nominalFrameRate) : 1.0 / 25.0

        let reader = try AVAssetReader(asset: asset)
        let settings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output: AVAssetReaderOutput
        // 手机竖拍等带旋转元数据的视频：TrackOutput 输出的是未旋转的帧，会和预览
        // （AVPlayer / FFmpeg 都按显示方向出图）对不上。用 VideoCompositionOutput
        // 让 AVFoundation 按 preferredTransform 渲染，两条后端方向一致。
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        if transform == .identity {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        } else {
            let compositionOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                                                                        videoSettings: settings)
            compositionOutput.videoComposition = AVMutableVideoComposition(propertiesOf: asset)
            output = compositionOutput
        }
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { throw FrameSamplerError.cannotAddOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw FrameSamplerError.readerFailed(reader.error?.localizedDescription ?? "无法启动解码器")
        }
        return (reader, output, frameDuration)
    }

    /// 解码并返回下一帧。返回 nil 表示解码结束或已取消。
    func next() -> SampledFrame? {
        guard !exhausted else { return nil }

        switch backend {
        case .avFoundation(let reader, let output):
            return autoreleasepool { nextFromAV(reader: reader, output: output) }
        case .ffmpeg(let process):
            return autoreleasepool {
                guard let frame = process.nextFrame() else {
                    exhausted = true
                    let text = process.errorDescription
                    // stderr 里有错误只说明文件局部损坏；只要解出过帧，
                    // 结果照常给，只有一帧都没解出来才算打不开。
                    if !text.isEmpty {
                        decodeErrors = true
                        if !decodedAny { failure = text }
                    }
                    return nil
                }
                decodedAny = true
                return SampledFrame(pixelBuffer: frame.buffer,
                                    time: frame.time,
                                    frameEnd: frame.time + fallbackFrameDuration)
            }
        }
    }

    private func nextFromAV(reader: AVAssetReader,
                            output: AVAssetReaderOutput) -> SampledFrame? {
        // 每帧一个 autorelease pool：CoreMedia / CoreVideo 会产生大量自动释放对象，
        // 后台线程没有默认的池，不主动排空就会一路堆积。
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                exhausted = true
                if reader.status == .failed {
                    decodeErrors = true
                    if !decodedAny {
                        failure = reader.error?.localizedDescription ?? "解码中断"
                    }
                }
                return nil
            }

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentationTime.isValid else { continue }

            let time = CMTimeGetSeconds(presentationTime)
            if time - lastEmitted < minInterval { continue }
            lastEmitted = time

            let sampleDuration = CMSampleBufferGetDuration(sample)
            let frameDuration = (sampleDuration.isValid && CMTimeGetSeconds(sampleDuration) > 0)
                ? CMTimeGetSeconds(sampleDuration)
                : fallbackFrameDuration

            decodedAny = true
            return SampledFrame(pixelBuffer: imageBuffer,
                                time: time,
                                frameEnd: time + frameDuration)
        }
    }

    func errorDescription() -> String? { failure }

    /// 解码过程中是否出过错（文件局部损坏）。结果仍可用，但调用方应提示可能不完整。
    func hadDecodeErrors() -> Bool { decodeErrors }

    func decoderInUse() -> VideoDecoderKind { usedDecoder }

    func cancel() {
        exhausted = true
        switch backend {
        case .avFoundation(let reader, _):
            reader.cancelReading()
        case .ffmpeg(let process):
            process.cancel()
        }
    }
}
