import Foundation

/// OCR 文本清洗：标点/空格/缩略语修正，导出前对每条字幕段应用。
///
/// 移植自 VSE（video-subtitle-extractor）`backend/tools/reformat.py` 的无分词子集，
/// 按本项目需要做了两处裁剪：
/// 1. 不含 wordsegment 分词 DP——那需要 ~3MB 词频数据打进包里，而它服务的
///    场景（英文整句粘连）在本项目的双语字幕里占比很低；
/// 2. 不移植 CamelCase 拆词规则（`helloWorld`→`hello World`）——它的误伤面更大：
///    iPhone / McDonald 这类品牌词在字幕里比粘连词常见得多。
/// 应用时机：聚合之后（ExtractionEngine），可在 GUI 参数面板或 `--no-refine` 关闭。
enum TextRefiner {

    /// 缩略语表：OCR 常把撇号丢掉（"I'm"→"im"）。键 = 去撇号小写形式。
    /// 来源：reformat.py 的 verb_forms（51 条）。其中 its / id / wed 本身是
    /// 正经英文单词，无脑替换会污染正常文本（VSE 靠分词器上下文规避，
    /// 我们没有分词，直接排除这三个键）。
    private static let contractionForms = [
        "I'm", "you're", "he's", "she's", "we're", "it's", "isn't", "aren't",
        "they're", "there's", "wasn't", "weren't", "I've", "you've", "we've",
        "they've", "hasn't", "haven't", "I'd", "you'd", "he'd", "she'd",
        "it'd", "we'd", "they'd", "doesn't", "don't", "didn't", "I'll",
        "you'll", "he'll", "she'll", "we'll", "they'll", "there'll", "there'd",
        "can't", "couldn't", "daren't", "hadn't", "mightn't", "mustn't",
        "needn't", "oughtn't", "shan't", "shouldn't", "usedn't", "won't",
        "wouldn't", "that's", "what's", "it'll",
    ]

    /// 常见 OCR 错字。来源：VSE typoMap.json（5 条），按需补充。
    private static let typoMap: [(wrong: String, right: String)] = [
        ("l'm", "I'm"), ("l just", "I just"), ("Let'sqo", "Let's go"),
        ("Iife", "life"), ("威筋", "威胁"),
    ]

    /// 内容修正（错字 + 缩略语），所有语种都应用
    private static let contentRules: [(regex: NSRegularExpression, template: String)] = {
        var rules: [(pattern: String, template: String)] = []
        for (wrong, right) in typoMap {
            rules.append(("(?i)" + NSRegularExpression.escapedPattern(for: wrong), right))
        }
        let unsafeKeys: Set<String> = ["its", "id", "wed"]
        for form in contractionForms {
            let key = form.replacingOccurrences(of: "'", with: "").lowercased()
            guard !unsafeKeys.contains(key) else { continue }
            rules.append(("(?i)\\b" + NSRegularExpression.escapedPattern(for: key) + "\\b", form))
        }
        return rules.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    /// 西文标点排版（全角→半角、标点后补空格）。只对非 CJK 行应用：
    /// 全角标点是中文/日文的正字法，转半角是劣化（VSE 一律转，此处不跟随）。
    private static let latinPunctuationRules: [(regex: NSRegularExpression, template: String)] = {
        let patterns: [(pattern: String, template: String)] = [
            ("，", ","), ("。", "."), ("！", "!"), ("？", "?"),
            ("；", ";"), ("：", ":"), ("（", "("), ("）", ")"),
            ("([.,!?;:])(?=[A-Za-z\\u4E00-\\u9FFF])", "$1 "),  // 标点后补空格（后随字符不含数字，保护小数）
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    /// CJK 行专属排版：去全角标点前的空格、去汉字之间的 OCR 噪声空格
    /// （reformat.py 的 Chinese prep 规则）。中文正字法里标点后不加空格。
    private static let cjkSpacingRules: [(regex: NSRegularExpression, template: String)] = {
        let patterns: [(pattern: String, template: String)] = [
            ("\\s+([，。！？；：、])", "$1"),
            ("\\s+([\\u4E00-\\u9FFF])", "$1"),
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    /// 通用排版（所有语种）
    private static let spacingRules: [(regex: NSRegularExpression, template: String)] = {
        let patterns: [(pattern: String, template: String)] = [
            ("\\s+([,.!?;:%])", "$1"),                          // 去掉标点前的空格
            // 撇号粘合：只粘确认为缩略语后缀的形状（it ' s → it's），
            // 避免误伤正经的引号用法（the 'big' one）
            ("(?i)([A-Za-z])\\s*'\\s*(ll|re|ve|s|t|d|m)\\b", "$1'$2"),
            ("([A-Za-z0-9]) - ([A-Za-z0-9])", "$1-$2"),         // 两侧都有空格的连字符粘合
            ("\\s*·\\s*$", "."),                                // 行尾中点（OCR 的句点误识）
            ("[ ]{2,}", " "),                                   // 多余空格
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    /// 段内连续空行折叠成单换行
    private static let blankLineCollapser = try? NSRegularExpression(pattern: "\\n{2,}")

    /// 应用到一条字幕文本（可能多行，逐行清洗）。
    /// 按整段语种分流：CJK 行保留全角标点，西文行走完整排版链。
    static func refine(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let cjk: Bool = {
            switch SubtitleLanguage.classify(text) {
            case .chinese, .japanese, .korean: return true
            case .english, .unknown: return false
            }
        }()
        var result = text.components(separatedBy: "\n")
            .map { refineLine($0, cjk: cjk) }
            .joined(separator: "\n")
        if let collapser = blankLineCollapser {
            let range = NSRange(result.startIndex..., in: result)
            result = collapser.stringByReplacingMatches(in: result, range: range, withTemplate: "\n")
        }
        return result
    }

    private static func refineLine(_ raw: String, cjk: Bool) -> String {
        var text = raw
        // 每条规则都可能改变字符串长度，range 必须在应用前重算，
        // 否则旧 range 越界（NSRangeException）
        func apply(_ rules: [(regex: NSRegularExpression, template: String)], to text: inout String) {
            for (regex, template) in rules {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            }
        }
        apply(contentRules, to: &text)
        if cjk {
            apply(cjkSpacingRules, to: &text)
        } else {
            apply(latinPunctuationRules, to: &text)
        }
        apply(spacingRules, to: &text)
        return text.trimmingCharacters(in: .whitespaces)
    }
}
