import Foundation
import CoreGraphics

enum SubtitleLanguage: String, Codable, CaseIterable {
    case chinese
    case english
    case japanese
    case korean
    case unknown

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        case .japanese: return "日文"
        case .korean: return "韩文"
        case .unknown: return "未知"
        }
    }

    /// 按字符分布判断语种。字幕行通常很纯，这个朴素规则够用。
    static func classify(_ text: String) -> SubtitleLanguage {
        var han = 0, kana = 0, hangul = 0, latin = 0, other = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                han += 1
            case 0x3040...0x309F, 0x30A0...0x30FF:
                kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF:
                hangul += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            case 0x20, 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
                other += 1
            default:
                other += 1
            }
        }

        // 有假名一律当日文：日文里汉字占比很高，只看汉字会误判
        if kana > 0 { return .japanese }
        if hangul > 0 { return .korean }

        let total = han + kana + hangul + latin
        guard total > 0 else { return .unknown }
        if han > 0, Double(han) / Double(total) > 0.3 { return .chinese }
        if latin > 0, Double(latin) / Double(total) > 0.6 { return .english }
        return .unknown
    }
}

/// 字幕行锚点：一条固定的字幕行在画面上的位置。
///
/// 相比「一个矩形 ROI」，锚点区分了每一行，带来三个实际好处：
/// 1. 每行独立判重，一行变了不会连带另一行重新识别；
/// 2. 双语字幕天然是两条锚点，输出成两条独立文本而不是用换行拼在一起；
/// 3. 每行单独记录宽度统计，用来判断检测框是不是真的字幕（而不是画面里的招牌）。
struct SubtitleAnchor: Identifiable, Hashable {
    var id = UUID()
    /// 归一化坐标，左上原点
    var rect: CGRect
    var language: SubtitleLanguage = .unknown
    /// 主字幕（通常是译文/原文中更主要的那条），用于排序与导出取舍
    var isPrimary: Bool = true
    /// 在扫描阶段命中的帧数，越高越可信
    var hits: Int = 0
    /// 检测到的文本宽度统计（归一化），用于过滤异常宽的框
    var maxWidth: CGFloat = 0

    var centerY: CGFloat { rect.midY }
    var height: CGFloat { rect.height }

    var displayName: String {
        "\(language.displayName) · y\(String(format: "%.2f", rect.midY))"
    }

    /// 把锚点矩形向外扩一点再裁，避免把字顶或字底切掉
    func expanded(padding: CGFloat = 0.25) -> CGRect {
        let dy = rect.height * padding
        let dx = rect.height * padding * 0.4
        return CGRect(x: rect.minX - dx,
                      y: rect.minY - dy,
                      width: rect.width + dx * 2,
                      height: rect.height + dy * 2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
