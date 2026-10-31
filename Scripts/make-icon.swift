import AppKit
import CoreGraphics
import Foundation

// 生成 macOS 应用图标。
//
// 图形语言：一块深色屏幕，底部一条暖白色的字幕条，条里两行居中的文字。
// 不做渐变文字、不做光晕、不加装饰线条 —— 图标只讲一件事：视频上的字幕。
//
// 尺寸遵循 macOS 图标网格：1024 画布，主体 824，四周留 100。

let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100
let bodyRect = CGRect(x: bodyInset, y: bodyInset,
                      width: canvas - bodyInset * 2,
                      height: canvas - bodyInset * 2)

/// 超椭圆（squircle）。Apple 的图标外形接近 n≈5 的超椭圆，
/// 用参数方程采样成多边形，比圆角矩形更接近系统观感。
func squirclePath(in rect: CGRect, n: CGFloat = 5.0, samples: Int = 720) -> CGPath {
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let exponent = 2 / n

    let path = CGMutablePath()
    for index in 0...samples {
        let t = CGFloat(index) / CGFloat(samples) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), exponent)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), exponent)
        if index == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func renderIcon() -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil,
                        width: Int(canvas),
                        height: Int(canvas),
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let shape = squirclePath(in: bodyRect)

    // 1. 投影：让图标在浅色桌面背景上有落点
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12),
                  blur: 34,
                  color: rgb(0x000000, alpha: 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x14171D))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. 主体渐变：一次画完，避免多段渐变叠出接缝
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let base = CGGradient(colorsSpace: space,
                          colors: [rgb(0x353D4E), rgb(0x232935), rgb(0x11141A)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: 0, y: bodyRect.maxY),
                           end: CGPoint(x: 0, y: bodyRect.minY),
                           options: [])

    // 3. 上方一片柔和的光，像投影打在屏幕上；用光而不是加物件来填满上半部分
    let glow = CGGradient(colorsSpace: space,
                          colors: [rgb(0xFFFFFF, alpha: 0.12),
                                   rgb(0xFFFFFF, alpha: 0.04),
                                   rgb(0xFFFFFF, alpha: 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: canvas / 2, y: bodyRect.maxY - 40),
                           startRadius: 0,
                           endCenter: CGPoint(x: canvas / 2, y: bodyRect.maxY - 40),
                           endRadius: 470,
                           options: [])

    // 屏幕内沿的一道细边，界定「屏幕」和「外壳」
    let bezel = squirclePath(in: bodyRect.insetBy(dx: 7, dy: 7))
    ctx.addPath(bezel)
    ctx.setStrokeColor(rgb(0xFFFFFF, alpha: 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()

    ctx.restoreGState()

    // 4. 字幕条
    let barWidth: CGFloat = 640
    let barHeight: CGFloat = 152
    let barRect = CGRect(x: (canvas - barWidth) / 2,
                         y: bodyRect.minY + 118,
                         width: barWidth,
                         height: barHeight)
    let barPath = CGPath(roundedRect: barRect,
                         cornerWidth: 30,
                         cornerHeight: 30,
                         transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -9),
                  blur: 22,
                  color: rgb(0x000000, alpha: 0.30))
    ctx.addPath(barPath)
    ctx.setFillColor(rgb(0xFBF3E4))
    ctx.fillPath()
    ctx.restoreGState()

    // 条内一层极淡的暖色渐变，避免大色块死板
    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    let barShade = CGGradient(colorsSpace: space,
                              colors: [rgb(0xFFFFFF), rgb(0xF3E7D3)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(barShade,
                           start: CGPoint(x: 0, y: barRect.maxY),
                           end: CGPoint(x: 0, y: barRect.minY),
                           options: [])
    ctx.restoreGState()

    // 5. 两行居中的文字，长短不一，像真实字幕
    let lines: [(width: CGFloat, bottom: CGFloat)] = [
        (470, barRect.maxY - 78),
        (348, barRect.maxY - 132)
    ]
    let lineHeight: CGFloat = 32
    for line in lines {
        let rect = CGRect(x: (canvas - line.width) / 2,
                          y: line.bottom,
                          width: line.width,
                          height: lineHeight)
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: lineHeight / 2,
                           cornerHeight: lineHeight / 2,
                           transform: nil))
        ctx.setFillColor(rgb(0x191C23))
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

// MARK: - 输出各尺寸

let master = renderIcon()
let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1
                  ? CommandLine.arguments[1]
                  : "build/AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

let space = CGColorSpaceCreateDeviceRGB()
for variant in variants {
    let size = variant.size
    let ctx = CGContext(data: nil,
                        width: size,
                        height: size,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

// 同时留一张 1024 的预览图，方便检查
let previewRep = NSBitmapImageRep(cgImage: master)
try! previewRep.representation(using: .png, properties: [:])!
    .write(to: iconset.deletingLastPathComponent().appendingPathComponent("AppIcon-preview.png"))

print("已生成 iconset：\(iconset.path)")
