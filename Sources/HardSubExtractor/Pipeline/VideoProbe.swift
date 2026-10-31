import Foundation
import AVFoundation
import CoreMedia

/// 导入时的视频体检结果。
///
/// 存在的意义：AVFoundation 对容器和编码的支持是有限的。用户拖进来一个文件，
/// 如果等到点「开始提取」才报一句「解码失败」，既看不出原因也不知道怎么补救。
struct VideoProbeResult {
    var duration: Double = 0
    var naturalSize: CGSize = .zero
    /// 编码的人类可读描述，例如 "H.264 High"、"H.264 High 10"
    var codec: String = "未知"
    /// 编码本身是否被 AVFoundation 支持（不看具体文件是否损坏）
    var codecSupported = true
    var isDecodable = false
    /// 最终用哪个解码器
    var decoder: VideoDecoderKind = .avFoundation
    /// 不阻断流程的提示（例如「已自动改用 FFmpeg」）
    var note: String?
    /// 不能解码时给用户看的完整说明
    var problem: String?
}

enum VideoProbe {

    static func probe(url: URL) async -> VideoProbeResult {
        var result = VideoProbeResult()

        let asset = AVURLAsset(url: url)
        let tracks = try? await asset.loadTracks(withMediaType: .video)

        // AVFoundation 连容器都打不开（MKV / AVI / FLV …）→ 直接交给 FFmpeg
        guard let track = tracks?.first else {
            if let info = FFmpegProcess.probe(url: url) {
                result.duration = info.duration
                result.naturalSize = CGSize(width: info.width, height: info.height)
                result.codec = info.codec
                result.codecSupported = false
                result.isDecodable = true
                result.decoder = .ffmpeg
                result.note = "AVFoundation 读不了这种容器，已改用 FFmpeg 解码。"
                return result
            }
            result.problem = tracks == nil
                ? """
                这个文件打不开，FFmpeg 也读不出视频流。

                常见原因是文件损坏、没有下载完整，或者根本不是视频文件。
                """
                : """
                这个文件里没有视频轨道。

                如果它其实是音频文件或图片序列，就没法提取字幕。
                """
            return result
        }

        if let seconds = try? await asset.load(.duration).seconds, seconds > 0 {
            result.duration = seconds
        }
        if let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
            // naturalSize 是编码尺寸；竖拍等带旋转元数据的视频要换成显示尺寸，
            // 否则画面比例、ROI 叠加框和实际帧都对不上
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let display = size.applying(transform)
            let rotated = CGSize(width: abs(display.width), height: abs(display.height))
            if rotated.width > 0, rotated.height > 0 {
                result.naturalSize = rotated
            } else {
                result.naturalSize = size
            }
        }

        let info = await codecInfo(of: track)
        result.codec = info.label
        result.codecSupported = info.supported

        // 编码被 AVFoundation 支持，且真能解出一帧 → 用 AVFoundation（硬件加速最快）
        if info.supported, await decodeFailure(asset: asset, track: track) == nil {
            result.isDecodable = true
            result.decoder = .avFoundation
            return result
        }

        // 否则看 FFmpeg 能不能兜住
        if let ffInfo = FFmpegProcess.probe(url: url) {
            result.duration = ffInfo.duration > 0 ? ffInfo.duration : result.duration
            if result.naturalSize == .zero {
                result.naturalSize = CGSize(width: ffInfo.width, height: ffInfo.height)
            }
            result.isDecodable = true
            result.decoder = .ffmpeg
            result.note = info.supported
                ? "AVFoundation 解不出这个文件的画面，已改用 FFmpeg 解码。"
                : "\(info.reason ?? "AVFoundation 不支持 \(info.label)")已改用 FFmpeg 解码。"
            return result
        }

        result.isDecodable = false
        if info.supported {
            result.problem = decodeFailedMessage(codec: info.label,
                                                 reason: "读不出画面帧。")
        } else {
            result.problem = unsupportedMessage(info)
        }
        return result
    }

    // MARK: - 编码识别

    private struct CodecInfo {
        var label: String
        var supported: Bool
        /// 不支持的细分原因，用于生成文案
        var reason: String?
    }

    private static func codecInfo(of track: AVAssetTrack) async -> CodecInfo {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first else {
            return CodecInfo(label: "未知", supported: true)
        }

        let subType = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [UInt8((subType >> 24) & 0xFF), UInt8((subType >> 16) & 0xFF),
                     UInt8((subType >> 8) & 0xFF), UInt8(subType & 0xFF)]
        let fourCC = String(bytes: bytes, encoding: .ascii) ?? "????"

        switch fourCC {
        case "avc1", "avc3":
            if let profile = h264Profile(from: description), profile.unsupported {
                return CodecInfo(label: "H.264 \(profile.name)",
                                 supported: false,
                                 reason: profile.reason)
            }
            let name = h264Profile(from: description)?.name ?? ""
            return CodecInfo(label: name.isEmpty ? "H.264" : "H.264 \(name)", supported: true)

        case "hvc1", "hev1":
            let depth = bitDepth(from: description)
            return CodecInfo(label: depth > 8 ? "H.265 (\(depth)-bit)" : "H.265", supported: true)

        case "av01":
            return CodecInfo(label: "AV1", supported: false,
                             reason: "AV1 的支持取决于芯片和系统版本，这台机器解不了。")
        case "vp09", "vp08":
            return CodecInfo(label: "VP9", supported: false,
                             reason: "AVFoundation 不支持 VP9。")
        case "mp4v":
            return CodecInfo(label: "MPEG-4", supported: true)
        case "ap4h", "ap4x", "apcn", "apcs", "apco", "apch":
            return CodecInfo(label: "ProRes", supported: true)
        case "dvh1", "dvhe":
            return CodecInfo(label: "Dolby Vision", supported: false,
                             reason: "Dolby Vision 的增强层 AVFoundation 解不了。")
        default:
            return CodecInfo(label: fourCC, supported: false,
                             reason: "系统不认识这个编码（\(fourCC)）。")
        }
    }

    /// H.264 的 profile 藏在 avcC 原子第 1 个字节（profile_idc）。
    /// AVFoundation 只支持 8-bit 的 Baseline / Main / High，
    /// High 10 / High 4:2:2 / High 4:4:4 一律解不了 —— 这在压制组的片源里很常见。
    private static func h264Profile(from description: CMFormatDescription)
        -> (name: String, unsupported: Bool, reason: String?)? {

        guard let atoms = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
              ) as? [String: Any],
              let avcC = atoms["avcC"] as? Data,
              avcC.count >= 4 else { return nil }

        let profileIDC = avcC[avcC.startIndex + 1]
        switch profileIDC {
        case 66: return ("Baseline", false, nil)
        case 77: return ("Main", false, nil)
        case 88: return ("Extended", false, nil)
        case 100: return ("High", false, nil)
        case 110:
            return ("High 10", true,
                    "这是 10-bit 的 H.264（High 10 Profile），AVFoundation 只支持 8-bit 的 H.264。")
        case 122:
            return ("High 4:2:2", true,
                    "这是 4:2:2 色度的 H.264（High 4:2:2 Profile），AVFoundation 不支持。")
        case 244:
            return ("High 4:4:4", true,
                    "这是 4:4:4 色度的 H.264（High 4:4:4 Profile），AVFoundation 不支持。")
        default:
            return ("Profile \(profileIDC)", false, nil)
        }
    }

    private static func bitDepth(from description: CMFormatDescription) -> Int {
        // Depth 是每像素位数（8-bit 4:2:0 通常是 24）
        guard let depth = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_Depth
              ) as? Int, depth > 0 else { return 8 }
        switch depth {
        case 0...24: return 8
        case 25...30: return 10
        case 31...36: return 12
        default: return 8
        }
    }

    // MARK: - 文案

    private static func unsupportedMessage(_ info: CodecInfo) -> String {
        """
        这个视频的编码解不了：\(info.label)
        \(info.reason ?? "")

        需要转码成 8-bit 的 H.264 或 H.265（MP4）再试。
        HandBrake、Shutter Encoder 都能做，导出时选 H.264（不要选 10-bit）。
        """
    }

    private static func decodeFailedMessage(codec: String, reason: String) -> String {
        """
        系统读不出这个视频的画面：\(codec)
        \(reason)

        编码本身是支持的，所以更可能是文件本身有问题：
        · 文件没有下载完整，或者中间有损坏
        · 文件是从别的格式改后缀得来的
        · 文件被加密或有版权保护

        先用播放器（比如 IINA）打开试试，播不了就是文件本身的问题。
        能播的话，用 HandBrake 重新封装一次通常就好了。
        """
    }

    // MARK: - 解码试跑

    /// 在片头、10%、50% 三处各试解几帧。
    /// 只试开头一帧容易误判：有些文件开头是开放 GOP，需要多读几帧才能出画面。
    private static func decodeFailure(asset: AVURLAsset, track: AVAssetTrack) async -> String? {
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var positions: [Double] = [0]
        if duration > 20 {
            positions.append(duration * 0.1)
            positions.append(duration * 0.5)
        }

        var lastReason = "读不到任何画面帧。"
        for position in positions {
            if let reason = testDecode(asset: asset, track: track, at: position) {
                lastReason = reason
            } else {
                return nil
            }
        }
        return lastReason
    }

    /// 返回 nil 表示能解；否则返回失败原因
    private static func testDecode(asset: AVURLAsset,
                                   track: AVAssetTrack,
                                   at seconds: Double) -> String? {
        do {
            let reader = try AVAssetReader(asset: asset)
            if seconds > 0 {
                reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                               duration: .positiveInfinity)
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                return "无法为这个视频轨道创建解码输出。"
            }
            reader.add(output)
            guard reader.startReading() else {
                return reader.error?.localizedDescription ?? "解码器启动失败。"
            }

            // 多读几帧，避开开放 GOP 开头
            for _ in 0..<30 {
                guard let sample = output.copyNextSampleBuffer() else { break }
                if CMSampleBufferGetImageBuffer(sample) != nil {
                    reader.cancelReading()
                    return nil
                }
            }

            let failed = reader.status == .failed
            let reason = reader.error?.localizedDescription ?? "读不到任何画面帧。"
            reader.cancelReading()
            return failed ? reason : "读不到任何画面帧。"
        } catch {
            return error.localizedDescription
        }
    }
}
