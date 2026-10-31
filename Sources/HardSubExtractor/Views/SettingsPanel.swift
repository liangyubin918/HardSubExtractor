import SwiftUI

struct SettingsPanel: View {
    @Bindable var model: ExtractorViewModel
    @Binding var isExpanded: Bool
    /// 展开内容是否包 ScrollView。真实界面用 true（内容比面板高时滚动）；
    /// 离屏快照用 false（ImageRenderer 渲染不出 ScrollView 内容）。
    var scrollsWhenExpanded: Bool = true
    /// 展开内容的高度上限。macOS 的 DisclosureGroup 会把展开内容按「理想高度」
    /// 渲染、拒绝压缩——内容 ~700pt 比面板高时整个分栏溢出窗口，超出部分被裁掉
    /// 且 ScrollView 视口足够高、滚轮无事可做。必须用窗口传入的可用高度硬钳。
    var maxContentHeight: CGFloat = .infinity

    /// isExpanded 由父级持有：OutputPane 要根据展开状态决定是否显示字幕列表。
    /// 离屏快照传 .constant 即可（ImageRenderer 下无交互）。
    init(model: ExtractorViewModel,
         isExpanded: Binding<Bool> = .constant(false),
         scrollsWhenExpanded: Bool = true,
         maxContentHeight: CGFloat = .infinity) {
        self._model = Bindable(wrappedValue: model)
        self._isExpanded = isExpanded
        self.scrollsWhenExpanded = scrollsWhenExpanded
        self.maxContentHeight = maxContentHeight
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            panelContent
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text("提取参数")
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Badge(text: model.engine.title, tint: paddleUnavailable ? Theme.warning : Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 10)
    }

    // 展开后的参数内容（滑杆 + 开关 + 提示文字 ≈ 700pt）比右栏高，不套 ScrollView
    // 的话超出面板的部分会被直接裁掉：看不见也滚不到。
    @ViewBuilder
    private var panelContent: some View {
        let sections = VStack(alignment: .leading, spacing: Theme.sectionGap) {
            engineSection
            Divider()
            regionSection
            Divider()
            performanceSection
            Divider()
            languageSection
        }
        .padding(.top, 12)
        .padding(.bottom, 6)

        if scrollsWhenExpanded {
            ScrollView { sections }
                .frame(maxHeight: maxContentHeight)
        } else {
            sections
        }
    }

    // MARK: - 识别引擎

    private var paddleUnavailable: Bool {
        model.engine == .paddle && !model.paddleAvailable
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("识别引擎")
            Picker("", selection: $model.engine) {
                ForEach(OCREngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.engineStatusText)
                .font(Theme.meta)
                .foregroundStyle(paddleUnavailable ? Theme.warning : Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 字幕区域

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                label("字幕搜索范围")
                Spacer()
                Toggle("在画面上显示", isOn: $model.showsROIOverlay)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
            }

            // 用 Canvas 直接按传入的尺寸绘制，不依赖 GeometryReader 的布局协商，
            // 保证预览框和实际参数严格对应。
            Canvas { context, size in
                let width = size.width
                let height = size.height
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Theme.videoBackdrop))

                // 搜索范围：淡底
                let search = CGRect(x: model.roiLeft * width,
                                    y: model.roiTop * height,
                                    width: max(2, (model.roiRight - model.roiLeft) * width),
                                    height: max(2, (model.roiBottom - model.roiTop) * height))
                context.fill(Path(search), with: .color(Theme.accent.opacity(0.14)))
                context.stroke(Path(search), with: .color(Theme.accent.opacity(0.55)), lineWidth: 1)

                // 已检测到的字幕行：实心条
                for anchor in model.anchors {
                    let line = CGRect(x: anchor.rect.minX * width,
                                      y: anchor.rect.minY * height,
                                      width: max(2, anchor.rect.width * width),
                                      height: max(2, anchor.rect.height * height))
                    context.fill(Path(line), with: .color(Theme.accent.opacity(0.75)))
                }
            }
            .frame(height: 66)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                if model.anchors.isEmpty {
                    Text("还没分析字幕行")
                        .font(Theme.meta)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("\(model.anchors.count) 行：" + model.anchors.map(\.language.displayName).joined(separator: " / "))
                        .font(Theme.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("重新检测") { model.redetectAnchors() }
                    .controlSize(.mini)
                    .disabled(!model.hasVideo || model.isRunning)
                    .help("重新扫描片头，定位字幕行的位置（不影响已识别的字幕）")
            }

            slider("上边界", value: $model.roiTop, range: 0...0.94)
            slider("下边界", value: $model.roiBottom, range: 0.06...1)
            slider("左边界", value: $model.roiLeft, range: 0...0.9)
            slider("右边界", value: $model.roiRight, range: 0.1...1)

            Text("这里只是「去哪儿找字幕」。具体哪几行由自动分析决定，每行独立识别。")
                .font(Theme.meta)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 性能

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            label("性能")
            slider("采样帧率", value: $model.sampleFPS, range: 1...30, format: "%.0f fps")
                .help("每秒采样多少帧判断字幕变化：越高越准也越慢")
            slider("去重容差", value: $model.hashThreshold, range: 0...16, format: "%.0f")
                .help("画面变化多少才算「字幕变了」：调大更省识别、但可能漏掉细微变化")
            slider("放大倍数", value: $model.upscale, range: 1...3, format: "%.1f×")
                .help("识别前把字幕区域放大几倍，小字号片源建议 1.6×（PaddleOCR 不需要）")
            slider("确认帧数", value: $model.voteFrames, range: 1...5, format: "%.0f 帧")
                .help("字幕变化后额外多识别几帧投票定稿：越大越稳、越慢")

            Text("确认帧数越大越稳、越慢：1 帧比 3 帧快约 1.5 倍。")
                .font(Theme.meta)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("采样帧率越高越准也越慢。PaddleOCR 不额外放大。")
                .font(Theme.meta)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 语言与后处理

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("语言与后处理")
            Toggle("简体中文", isOn: $model.useSimplifiedChinese)
            Toggle("繁体中文", isOn: $model.useTraditionalChinese)
            Toggle("英文", isOn: $model.useEnglish)
            Toggle("语言纠正", isOn: $model.usesLanguageCorrection)
            Toggle("导出时过滤疑似水印", isOn: $model.filterWatermarks)

            HStack(spacing: 10) {
                Button("恢复默认") { model.resetSettings() }
                    .controlSize(.small)
                Spacer()
                if model.watermarkCount > 0 {
                    Text("\(model.watermarkCount) 条疑似水印")
                        .font(Theme.meta)
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.top, 2)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 12))
        .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - 组件

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: String = "%.2f") -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.meta)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 54, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(String(format: format, value.wrappedValue))
                .font(Theme.numeric)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}
