import Foundation
import CoreVideo
import CoreGraphics

/// 把 CVPixelBuffer 里的 BGRA 数据拷成紧凑的字节数组，
/// 后续所有裁剪、缩放都在纯 Swift 里做，避免反复进出 CoreImage。
struct BGRAImage {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
        let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = pixelWidth * 4

        var buffer = [UInt8](repeating: 0, count: rowBytes * pixelHeight)
        buffer.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if stride == rowBytes {
                target.update(from: source, count: rowBytes * pixelHeight)
            } else {
                for row in 0..<pixelHeight {
                    (target + row * rowBytes).update(from: source + row * stride, count: rowBytes)
                }
            }
        }

        width = pixelWidth
        height = pixelHeight
        bytes = buffer
    }

    @inline(__always)
    private func pixel(_ x: Int, _ y: Int) -> (b: Float, g: Float, r: Float) {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let offset = (clampedY * width + clampedX) * 4
        return (Float(bytes[offset]), Float(bytes[offset + 1]), Float(bytes[offset + 2]))
    }

    @inline(__always)
    private func sample(_ fx: Float, _ fy: Float) -> (b: Float, g: Float, r: Float) {
        let x0 = Int(fx.rounded(.down))
        let y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        let p00 = pixel(x0, y0)
        let p10 = pixel(x0 + 1, y0)
        let p01 = pixel(x0, y0 + 1)
        let p11 = pixel(x0 + 1, y0 + 1)

        let topB = p00.b + (p10.b - p00.b) * tx
        let topG = p00.g + (p10.g - p00.g) * tx
        let topR = p00.r + (p10.r - p00.r) * tx
        let bottomB = p01.b + (p11.b - p01.b) * tx
        let bottomG = p01.g + (p11.g - p01.g) * tx
        let bottomR = p01.r + (p11.r - p01.r) * tx

        return (topB + (bottomB - topB) * ty,
                topG + (bottomG - topG) * ty,
                topR + (bottomR - topR) * ty)
    }

    /// 从 sourceRect 双线性采样到 targetWidth x targetHeight，
    /// 写进 canvasWidth x canvasHeight 的 NCHW 画布（超出部分留 0）。
    /// 通道顺序固定为 BGR —— PaddleOCR 的模型是按 cv2 的 BGR 约定训练的。
    func normalizedCHW(sourceRect: CGRect,
                       targetWidth: Int,
                       targetHeight: Int,
                       canvasWidth: Int,
                       canvasHeight: Int,
                       mean: (Float, Float, Float),
                       std: (Float, Float, Float)) -> [Float] {
        let plane = canvasWidth * canvasHeight
        var output = [Float](repeating: 0, count: plane * 3)

        let scaleX = Float(sourceRect.width) / Float(targetWidth)
        let scaleY = Float(sourceRect.height) / Float(targetHeight)
        let originX = Float(sourceRect.origin.x)
        let originY = Float(sourceRect.origin.y)

        for y in 0..<min(targetHeight, canvasHeight) {
            let sy = originY + (Float(y) + 0.5) * scaleY - 0.5
            let rowOffset = y * canvasWidth
            for x in 0..<min(targetWidth, canvasWidth) {
                let sx = originX + (Float(x) + 0.5) * scaleX - 0.5
                let color = sample(sx, sy)
                let index = rowOffset + x
                output[index] = (color.b / 255 - mean.0) / std.0
                output[plane + index] = (color.g / 255 - mean.1) / std.1
                output[plane * 2 + index] = (color.r / 255 - mean.2) / std.2
            }
        }
        return output
    }
}
