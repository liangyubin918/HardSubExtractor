import SwiftUI

struct SubtitleListView: View {
    @Bindable var model: ExtractorViewModel
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "字幕") {
                HStack(spacing: 8) {
                    TextField("搜索字幕", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 120)
                        .help("按文本过滤字幕")

                    Text(countSummary)
                        .font(Theme.numeric)
                        .foregroundStyle(Theme.textTertiary)

                    if model.watermarkCount > 0 {
                        Button {
                            model.deleteWatermarkSegments()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.warning)
                        .help("删除全部疑似水印（\(model.watermarkCount) 条）")
                    }

                    Button {
                        model.removeBlankSegments()
                    } label: {
                        Image(systemName: "eraser")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textTertiary)
                    .help("删除识别为空的条目")
                    .disabled(model.segments.isEmpty)
                }
            }

            Divider()

            if model.segments.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var countSummary: String {
        let visible = searchText.isEmpty ? "" : " / 显示 \(visibleSegments.count)"
        return "\(model.segments.count) 条 · 覆盖 \(model.subtitleCoverage.shortTimecode)\(visible)"
    }

    /// 搜索过滤后的片段（保留原始序号）
    private var visibleSegments: [SubtitleSegment] {
        guard !searchText.isEmpty else { return model.segments }
        return model.segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleSegments, id: \.id) { segment in
                    let isLast = segment.id == model.segments.last?.id
                    let number = (model.segments.firstIndex(where: { $0.id == segment.id }) ?? 0) + 1
                    SubtitleRow(rowNumber: number,
                                segment: segment,
                                isActive: segment.contains(model.currentTime),
                                text: binding(for: segment),
                                onSeek: { model.seekAndPause(to: segment.start) },
                                onBeginEditing: { model.beginTextEdit() },
                                onEndEditing: { model.endTextEdit() },
                                onUpdateTimes: { start, end in
                                    model.updateSegmentTimes(id: segment.id, start: start, end: end)
                                },
                                onMerge: isLast ? nil : { model.mergeWithNext(id: segment.id) },
                                onDelete: { model.removeSegment(id: segment.id) })
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private func binding(for segment: SubtitleSegment) -> Binding<String> {
        Binding(
            get: {
                model.segments.first(where: { $0.id == segment.id })?.text ?? ""
            },
            set: { newValue in
                model.updateSegmentText(id: segment.id, text: newValue)
            }
        )
    }

    // MARK: - 空状态

    @ViewBuilder
    private var emptyState: some View {
        if model.isRunning {
            skeleton
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.textTertiary)

                Text(model.hasVideo ? "还没有识别结果" : "导入视频后在这里校对字幕")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                Text(model.hasVideo ? "点「开始提取」，或用 ⌘R" : "识别结果可以直接改，改完导出 SRT")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 识别中的骨架行，形状和真实行一致，结果出现时不会跳版
    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.textTertiary.opacity(0.10))
                        .frame(width: 16, height: 10)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.textTertiary.opacity(0.13))
                            .frame(width: [150, 190, 120, 170, 140, 185][index], height: 10)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.textTertiary.opacity(0.08))
                            .frame(width: 104, height: 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.pad)
                .padding(.vertical, 9)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 单行

struct SubtitleRow: View {
    let rowNumber: Int
    let segment: SubtitleSegment
    let isActive: Bool
    @Binding var text: String
    var onSeek: () -> Void = {}
    var onBeginEditing: () -> Void = {}
    var onEndEditing: () -> Void = {}
    var onUpdateTimes: (Double, Double) -> Void = { _, _ in }
    /// nil 表示没有下一条（不能合并）
    var onMerge: (() -> Void)? = nil
    var onDelete: () -> Void = {}

    @State private var isHovering = false
    @State private var isEditingTime = false
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var textFocused: Bool
    @FocusState private var startFieldFocused: Bool
    @FocusState private var endFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", rowNumber))
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20, alignment: .trailing)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                TextField("（空）", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...4)
                    .focused($textFocused)
                    .onChange(of: textFocused) { focused in
                        if focused { onBeginEditing() } else { onEndEditing() }
                    }

                HStack(spacing: 7) {
                    if isEditingTime {
                        timeEditors
                    } else {
                        timeDisplay
                    }

                    Text(String(format: "%.1fs", segment.duration))
                        .font(Theme.numeric)
                        .foregroundStyle(Theme.textTertiary)

                    if segment.isSuspectedWatermark {
                        Badge(text: "疑似水印", tint: Theme.warning, filled: true)
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textTertiary)
            .help("删除这一条")
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 8)
        .frame(minHeight: Theme.rowMinHeight, alignment: .top)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onMerge {
                Button("与下一条合并") { onMerge() }
                Divider()
            }
            Button("删除", role: .destructive) { onDelete() }
        }
    }

    // 时间码：平时是「点击跳转」按钮，铅笔切换成起止编辑
    private var timeDisplay: some View {
        HStack(spacing: 4) {
            Button(action: onSeek) {
                Text("\(segment.start.shortTimecode) → \(segment.end.shortTimecode)")
                    .font(Theme.numeric)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? Theme.accent : Theme.textSecondary)
            .help("跳到这一句")

            Button {
                startText = String(format: "%.2f", segment.start)
                endText = String(format: "%.2f", segment.end)
                isEditingTime = true
                startFieldFocused = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("编辑起止时间")
        }
    }

    private var timeEditors: some View {
        HStack(spacing: 4) {
            TextField("开始", text: $startText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(Theme.numeric)
                .frame(width: 62)
                .focused($startFieldFocused)
                .onSubmit(commitTimes)
            Text("→")
                .font(Theme.numeric)
                .foregroundStyle(Theme.textTertiary)
            TextField("结束", text: $endText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(Theme.numeric)
                .frame(width: 62)
                .focused($endFieldFocused)
                .onSubmit(commitTimes)
            Button(action: commitTimes) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("应用（回车）")
            Button {
                isEditingTime = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("取消")
        }
    }

    private func commitTimes() {
        guard let start = Double(startText), let end = Double(endText) else { return }
        onUpdateTimes(start, end)
        isEditingTime = false
    }

    private var rowBackground: some View {
        Group {
            if isActive {
                Theme.accent.opacity(0.11)
            } else if isHovering {
                Theme.textPrimary.opacity(0.045)
            } else {
                Color.clear
            }
        }
    }
}
