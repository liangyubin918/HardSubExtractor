import SwiftUI

/// 设计令牌。整个界面只从这里取间距、字号、颜色，
/// 避免每个视图各写一套导致节奏散掉。
///
/// 定位是 macOS 原生工具（Operate 类界面），所以：
/// - 字体全部用系统字体，不引入自定义字族
/// - 控件全部用系统控件，不自造形状
/// - 强调色只用于主操作、选中态、状态指示，不做装饰
enum Theme {

    // MARK: - 间距

    /// 面板内边距
    static let pad: CGFloat = 14
    /// 元素间距
    static let gap: CGFloat = 10
    /// 分组之间的间距
    static let sectionGap: CGFloat = 16

    // MARK: - 圆角

    /// 统一圆角：卡片、行、输入框、提示块
    static let radius: CGFloat = 8
    /// 小元素（徽章、胶囊）
    static let smallRadius: CGFloat = 5

    // MARK: - 字号
    //
    // 产品界面用固定字号，不用流式缩放。
    // 层级靠字重和颜色，不靠夸张的字号差。

    /// 面板标题
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    /// 正文 / 行内容
    static let body = Font.system(size: 12.5)
    /// 次要说明
    static let meta = Font.system(size: 11)
    /// 时间码、计数等数字，等宽对齐
    static let numeric = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// 强调数字（时长）
    static let numericStrong = Font.system(size: 11.5, weight: .medium, design: .monospaced)

    // MARK: - 颜色

    /// 面板底色（窗口背景）
    static let surface = Color(nsColor: .windowBackgroundColor)
    /// 次级面：工具条、状态条、列表行底色
    static let surfaceRaised = Color(nsColor: .controlBackgroundColor)
    /// 视频区域，恒定深色，不跟随明暗模式
    static let videoBackdrop = Color(red: 0.055, green: 0.062, blue: 0.078)
    /// 主要文字
    static let textPrimary = Color(nsColor: .labelColor)
    /// 次要文字
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    /// 辅助文字
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// 分隔线
    static let hairline = Color(nsColor: .separatorColor)
    /// 强调色：主操作、选中行、进度
    static let accent = Color.accentColor
    /// 警告（水印、不可用引擎）
    static let warning = Color(nsColor: .systemOrange)

    // MARK: - 尺寸

    /// 左侧播放区最小宽度
    static let playerMinWidth: CGFloat = 520
    /// 右侧面板最小宽度
    static let panelMinWidth: CGFloat = 430
    /// 列表行高
    static let rowMinHeight: CGFloat = 46
}

/// 统一的分区标题。整屏只用这一种，不额外加装饰性小标签。
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// 小徽章，用于引擎名、水印标记这类短标签
struct Badge: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(tint.opacity(filled ? 0.16 : 0.10))
            )
    }
}
