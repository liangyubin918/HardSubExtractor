import Foundation
import CoreImage
import CoreVideo
import CoreGraphics

/// 像素级工具：字幕区域裁剪、放大、感知哈希。
/// 所有 ROI 参数统一使用「左上角为原点」的归一化坐标（0...1），
/// 与 SwiftUI 的直觉一致，内部再转换成 CoreImage 的左下角原点。
final class PixelToolkit {
    static let shared = PixelToolkit()

    private let context: CIContext
    private let rgbSpace = CGColorSpaceCreateDeviceRGB()
    private let graySpace = CGColorSpaceCreateDeviceGray()

    private init() {
        // 关闭中间结果缓存，逐帧处理场景下缓存只会白白吃内存
        context = CIContext(options: [.cacheIntermediates: false])
    }

    // MARK: - 坐标转换

    /// 归一化 ROI（左上原点）→ CoreImage 像素矩形（左下原点）
    private func ciRect(from normalizedROI: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let x = normalizedROI.origin.x * width
        let y = (1 - normalizedROI.origin.y - normalizedROI.size.height) * height
        let w = normalizedROI.size.width * width
        let h = normalizedROI.size.height * height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - 裁剪 + 放大

    /// 从整帧中裁出字幕区域，并按 scale 放大后写入新的 CVPixelBuffer。
    /// 放大对小字号 / 低分辨率片源的中文识别率提升很明显。
    func cropBuffer(from buffer: CVPixelBuffer,
                    normalizedROI: CGRect,
                    scale: CGFloat) -> CVPixelBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        guard width > 1, height > 1 else { return nil }

        let source = CIImage(cvPixelBuffer: buffer)
        let rect = ciRect(from: normalizedROI, width: width, height: height)
            .integral
            .intersection(source.extent)
        guard rect.width >= 8, rect.height >= 8 else { return nil }

        let outW = max(8, Int((rect.width * scale).rounded()))
        let outH = max(8, Int((rect.height * scale).rounded()))
        let sx = CGFloat(outW) / rect.width
        let sy = CGFloat(outH) / rect.height

        // 先缩放再平移回原点，保证渲染目标坐标系从 (0,0) 开始
        let image = source
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: -rect.origin.x * sx,
                                               y: -rect.origin.y * sy))

        guard let output = makeBuffer(width: outW, height: outH) else { return nil }
        context.render(image,
                       to: output,
                       bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                       colorSpace: rgbSpace)
        return output
    }

    // MARK: - 感知哈希

    /// dHash：把字幕区域压到 9x16 灰度图，比较水平相邻像素亮度，得到 128 位指纹。
    /// 以前是 9x8——对「整块搜索区域」这种大 ROI 太粗：一条字幕只占最下面一行，
    /// 出现/消失可能恰好只翻转 4 个 bit，够不着去重阈值（实测汉明距离正好 = 4），
    /// 字幕会整个被当成「没变」。纵向加密到 16 行后，同样场景翻转 ~16 bit。
    /// 用于判断「这一帧和上一帧的字幕内容是否相同」，比逐像素比较抗噪。
    func dHash(from buffer: CVPixelBuffer, normalizedROI: CGRect) -> [UInt64] {
        let hashWidth = 9
        let hashHeight = 16
        var words = [UInt64](repeating: 0, count: 2)

        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let source = CIImage(cvPixelBuffer: buffer)
        let rect = ciRect(from: normalizedROI, width: width, height: height)
            .integral
            .intersection(source.extent)
        guard rect.width > 1, rect.height > 1,
              let cgImage = context.createCGImage(source, from: rect) else { return words }

        var pixels = [UInt8](repeating: 0, count: hashWidth * hashHeight)

        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: hashWidth,
                                      height: hashHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: hashWidth,
                                      space: graySpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: hashWidth, height: hashHeight))

            // 注意：必须通过裸指针读取，否则会与 withUnsafeMutableBytes 形成重叠访问
            let p = raw.bindMemory(to: UInt8.self)
            var bit = 0
            for y in 0..<hashHeight {
                for x in 0..<(hashWidth - 1) {
                    if p[y * hashWidth + x] < p[y * hashWidth + x + 1] {
                        words[bit / 64] |= (UInt64(1) << UInt64(bit % 64))
                    }
                    bit += 1
                }
            }
        }
        return words
    }

    static func hamming(_ a: [UInt64], _ b: [UInt64]) -> Int {
        guard a.count == b.count else { return .max }
        return zip(a, b).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    // MARK: - 缓冲区

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}
