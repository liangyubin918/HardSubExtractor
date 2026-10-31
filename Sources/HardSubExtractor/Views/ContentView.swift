import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model: ExtractorViewModel

    @MainActor
    init(model: ExtractorViewModel? = nil) {
        _model = State(initialValue: model ?? ExtractorViewModel())
        UnsavedChangesGate.shared.model = _model.wrappedValue
    }

    var body: some View {
        // GeometryReader 里铺满整个窗口可用区域；参数页展开时右栏整体让位，
        // 收起时回到字幕列表，高度不够都由各自的 ScrollView 接管滚动。
        GeometryReader { _ in
            EditorSplitView(model: model)
        }
        .frame(minWidth: 980, minHeight: 640)
        .navigationTitle(model.hasVideo ? model.displayName : "硬字幕提取器")
            .navigationSubtitle(model.hasVideo ? model.videoResolution : "")
            .focusedSceneValue(\.extractor, model)
            .toolbar { toolbarContent }
            .fileImporter(isPresented: $model.isImporterPresented,
                          allowedContentTypes: [.audiovisualContent],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.load(url: url) }
                case .failure(let error):
                    model.errorMessage = "导入失败：\(error.localizedDescription)"
                }
            }
            .alert("提示", isPresented: errorBinding) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task {
                // 开发用：--gui <视频> [--autorun] 免点击驱动
                guard let url = LaunchOptions.initialVideo, !model.hasVideo else { return }
                if LaunchOptions.expandSettings {
                    model.settingsExpanded = true
                }
                model.load(url: url)
                if LaunchOptions.autoPlay {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    model.player?.play()
                }
                if LaunchOptions.autoStart {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    model.start()
                }
            }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    // 工具栏按工作流排列：打开 → 提取 → 导出，一个动作簇。
    // 图标语义遵循平台惯例：folder=打开，captions.bubble=提取字幕，
    // square.and.arrow.up=导出；开始提取是唯一的主操作（accent 实底）。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.isImporterPresented = true
            } label: {
                Label("打开视频", systemImage: "folder")
            }
            .labelStyle(.titleAndIcon)
            .help("选择带硬字幕的视频文件（⌘O）")

            if model.isRunning {
                Button {
                    model.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("停止提取，已识别的部分会保留（⌘.）")
            } else {
                Button {
                    model.start()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "captions.bubble")
                        Text("开始提取")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .help(model.videoProblem != nil ? "这个视频解不了，先看提示" : (model.hasVideo ? "开始识别字幕（⌘R）" : "先打开一个视频"))
            }

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title) { model.export(as: format) }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.exportableSegments.isEmpty)
            .help("导出字幕文件（⌘E 绑定最近使用的格式）")
        }
    }
}

// MARK: - 分栏容器

/// 左播放区 + 右输出栏。
///
/// 以前用 HSplitView，但它（AppKit 桥接）的高度恒等于「子栏内容的理想高度」：
/// 参数页展开后内容约 800pt、比窗口还高，整个分栏就溢出窗口，超出部分被裁掉，
/// 内部的 ScrollView 因为视口足够高而永远不会滚动 —— 用户看到的就是
/// 「展开参数后滚不动」。实测它对 min/max 约束和固定 frame 都不理会，
/// 所以这里改为 GeometryReader + HStack 的确定性布局：分栏高度恒等于
/// 可用高度，放不下时由参数页/列表各自的 ScrollView 接管滚动。
/// 分隔条保留拖拽调宽。
struct EditorSplitView: View {
    @Bindable var model: ExtractorViewModel
    /// 拖动分栏线后的左栏宽度；nil = 按窗口宽度 62% 起步
    @State private var leftWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let minLeft = Theme.playerMinWidth
            let maxLeft = max(minLeft, proxy.size.width - Theme.panelMinWidth)
            let resolved = min(max(leftWidth ?? proxy.size.width * 0.62, minLeft), maxLeft)
            HStack(spacing: 0) {
                PlayerPane(model: model)
                    .frame(width: resolved)
                paneDivider(clampedTo: minLeft...maxLeft)
                OutputPane(model: model, availableHeight: proxy.size.height)
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "split")
        }
    }

    private func paneDivider(clampedTo bounds: ClosedRange<CGFloat>) -> some View {
        ZStack {
            Divider()
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                .onChanged { value in
                    leftWidth = min(max(value.location.x, bounds.lowerBound), bounds.upperBound)
                }
        )
    }
}

// MARK: - 左：播放区

struct PlayerPane: View {
    @Bindable var model: ExtractorViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.hasVideo {
                fileStrip
                Divider()
            }

            ZStack {
                Theme.videoBackdrop
                if model.isAdjustingROI {
                    // 调整模式：静态帧替换播放器（AppKit 视图会吞掉 Overlay 的手势）
                    if let image = model.roiAdjustImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                } else if model.isFallbackPreview {
                    stillPreview
                } else if model.player != nil {
                    VideoPlayerView(player: model.player)
                } else {
                    emptyState
                }

                if model.showsROIOverlay,
                   model.player != nil || model.isFallbackPreview || model.isAdjustingROI {
                    let interactive = !model.isRunning && (model.isFallbackPreview || model.isAdjustingROI)
                    AnchorOverlay(searchROI: model.roi,
                                  anchors: model.anchors,
                                  aspect: model.videoAspect,
                                  onUpdateROI: interactive ? { model.updateROI($0) } : nil)
                }

                if let current = model.currentSegment {
                    subtitleOverlay(text: current.text)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.isFallbackPreview {
                Divider()
                scrubBar
            }
            Divider()
            statusStrip
        }
        .background(Theme.surface)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url: url)
            return true
        }
    }

    // MARK: 文件信息条

    private var fileStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            Text(model.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if !model.videoResolution.isEmpty {
                Text(model.videoResolution)
                    .font(Theme.numeric)
                    .foregroundStyle(Theme.textTertiary)
            }
            if !model.videoCodec.isEmpty {
                Badge(text: model.videoCodec,
                      tint: model.videoProblem == nil ? Theme.textSecondary : Theme.warning,
                      filled: model.videoProblem != nil)
            }
            if model.decoderKind == .ffmpeg {
                Badge(text: "FFmpeg", tint: Theme.accent, filled: true)
                    .help("这个格式 AVFoundation 解不了，正在用 FFmpeg 解码")
            }
            if model.videoDuration > 0 {
                Text(model.videoDuration.shortTimecode)
                    .font(Theme.numeric)
                    .foregroundStyle(Theme.textTertiary)
            }

            Button {
                model.seekToPreviousSegment()
            } label: {
                Image(systemName: "backward.end")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .help("跳到上一句")
            .disabled(model.segments.isEmpty)

            Button {
                model.seekToNextSegment()
            } label: {
                Image(systemName: "forward.end")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .help("跳到下一句")
            .disabled(model.segments.isEmpty)

            Button {
                model.showsROIOverlay.toggle()
            } label: {
                Image(systemName: model.showsROIOverlay ? "rectangle.dashed" : "rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.showsROIOverlay ? Theme.accent : Theme.textTertiary)
            .help(model.showsROIOverlay ? "隐藏字幕区域框" : "显示字幕区域框")

            if !model.isFallbackPreview {
                Button {
                    if model.isAdjustingROI {
                        model.endROIAdjust()
                    } else {
                        model.beginROIAdjust()
                    }
                } label: {
                    Image(systemName: model.isAdjustingROI ? "checkmark" : "viewfinder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.isAdjustingROI ? Theme.accent : Theme.textSecondary)
                .disabled(model.isRunning)
                .help(model.isAdjustingROI ? "完成调整" : "在当前画面上拖拽调整字幕搜索区域")
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 8)
        .background(Theme.surfaceRaised)
    }

    // MARK: 抽帧预览（AVPlayer 解不了的格式）

    @ViewBuilder
    private var stillPreview: some View {
        if let image = model.previewImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(model.previewLoading ? 0.6 : 1)
                .animation(.easeOut(duration: 0.12), value: model.previewLoading)
        } else {
            VStack(spacing: 9) {
                if model.previewLoading {
                    ProgressView().controlSize(.small)
                }
                Text(model.previewLoading ? "正在取画面…" : "这个格式没法直接播放")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Text("拖动下方进度条查看画面，字幕提取不受影响")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private var scrubBar: some View {
        HStack(spacing: 9) {
            Text(model.currentTime.shortTimecode)
                .font(Theme.numeric)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 46, alignment: .leading)

            Slider(value: Binding(get: { model.currentTime },
                                  set: { model.seek(to: $0) }),
                   in: 0...max(0.2, model.videoDuration))
                .controlSize(.small)

            Text(model.videoDuration.shortTimecode)
                .font(Theme.numeric)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 5)
        .background(Theme.surfaceRaised)
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.40))

            Text("还没有打开视频")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .padding(.top, 14)

            Text("拖入文件，或者直接选择")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.58))
                .padding(.top, 5)

            Button {
                model.isImporterPresented = true
            } label: {
                Label("打开视频", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 18)

            Text("MP4、MOV、MKV、AVI 等常见格式")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.46))
                .padding(.top, 12)
        }
    }

    // MARK: 字幕预览叠加

    private func subtitleOverlay(text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.62),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.horizontal, 44)
                .padding(.bottom, 54)
        }
        .allowsHitTesting(false)
    }

    // MARK: 状态条

    private var statusStrip: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12)
                    if !model.phaseText.isEmpty {
                        Badge(text: model.phaseText, tint: Theme.accent, filled: true)
                    }
                }
                Text(model.statusText)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 10)

                if let exportedURL = model.exportedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.meta)
                    .help("在 Finder 中显示导出的文件")
                }

                if model.analyzedFrameCount > 0 {
                    Text("OCR \(model.analyzedFrameCount) 帧")
                        .font(Theme.numeric)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .opacity(model.isRunning || model.progress > 0 ? 1 : 0.16)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 9)
        .background(Theme.surfaceRaised)
    }
}

// MARK: - 字幕行叠加框

/// 视频画面上的搜索区域框 + 已检测锚点。
/// 传入 onUpdateROI 时搜索框可拖动/缩放（8 个手柄 + 内部拖移），
/// 未传入时保持纯展示。
struct AnchorOverlay: View {
    let searchROI: CGRect
    let anchors: [SubtitleAnchor]
    let aspect: CGFloat
    var onUpdateROI: ((CGRect) -> Void)? = nil

    /// 拖拽手柄：(-1|0|1, -1|0|1)，-1/1 表示往哪边拉伸，0 表示这条边不动
    private static let handles: [(Int, Int)] = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1)
    ]

    @State private var dragStartROI: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fittedRect(aspect: aspect, in: geometry.size)

            ZStack(alignment: .topLeading) {
                searchRect(fitted: fitted)

                // 已识别的字幕行：实心描边 + 语种标签（只展示，不拦截点击）
                ForEach(anchors) { anchor in
                    let rect = Self.map(anchor.rect, into: fitted)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.95), lineWidth: 1.5)
                        .background(Theme.accent.opacity(0.12))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)

                    if rect.height > 22, rect.width > 56 {
                        Text(anchor.language.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                            .offset(x: rect.minX, y: max(0, rect.minY - 14))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// 搜索范围框：虚线矩形 + 手柄。整个视图只在这里拦截点击，其余区域
    /// （播放控制、播放器自身手势）不受影响。
    @ViewBuilder
    private func searchRect(fitted: CGRect) -> some View {
        let search = Self.map(searchROI, into: fitted)
        let base = RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color.white.opacity(0.32),
                          style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .frame(width: search.width, height: search.height)
            .offset(x: search.minX, y: search.minY)

        if let onUpdateROI {
            base
                .background(Color.white.opacity(0.02))
                .contentShape(Rectangle())
                .gesture(moveGesture(fitted: fitted, onUpdate: onUpdateROI))
                .overlay {
                    ForEach(Self.handles.indices, id: \.self) { index in
                        let (hx, hy) = Self.handles[index]
                        Circle()
                            .fill(Theme.accent)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .frame(width: 9, height: 9)
                            .position(x: search.minX + (CGFloat(hx) + 1) / 2 * search.width,
                                      y: search.minY + (CGFloat(hy) + 1) / 2 * search.height)
                            .gesture(resizeGesture(handle: (hx, hy),
                                                   fitted: fitted,
                                                   onUpdate: onUpdateROI))
                    }
                }
        } else {
            base
        }
    }

    private func moveGesture(fitted: CGRect, onUpdate: @escaping (CGRect) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartROI == nil { dragStartROI = searchROI }
                guard let start = dragStartROI else { return }
                let dx = value.translation.width / max(1, fitted.width)
                let dy = value.translation.height / max(1, fitted.height)
                var moved = start
                moved.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
                onUpdate(moved)
            }
            .onEnded { _ in dragStartROI = nil }
    }

    private func resizeGesture(handle: (Int, Int),
                               fitted: CGRect,
                               onUpdate: @escaping (CGRect) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartROI == nil { dragStartROI = searchROI }
                guard let start = dragStartROI else { return }
                let (hx, hy) = handle
                let dx = value.translation.width / max(1, fitted.width)
                let dy = value.translation.height / max(1, fitted.height)
                var minX = start.minX
                var minY = start.minY
                var maxX = start.maxX
                var maxY = start.maxY
                if hx < 0 { minX = min(max(start.minX + dx, 0), maxX - 0.05) }
                if hx > 0 { maxX = max(min(start.maxX + dx, 1), minX + 0.05) }
                if hy < 0 { minY = min(max(start.minY + dy, 0), maxY - 0.02) }
                if hy > 0 { maxY = max(min(start.maxY + dy, 1), minY + 0.02) }
                onUpdate(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
            .onEnded { _ in dragStartROI = nil }
    }

    private static func map(_ rect: CGRect, into fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + rect.minX * fitted.width,
               y: fitted.minY + rect.minY * fitted.height,
               width: rect.width * fitted.width,
               height: rect.height * fitted.height)
    }

    /// 视频在等比缩放的容器里实际占据的矩形
    static func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard size.width > 1, size.height > 1, aspect > 0 else { return .zero }
        let containerAspect = size.width / size.height
        if aspect > containerAspect {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }
}

// MARK: - 右：参数与列表

struct OutputPane: View {
    @Bindable var model: ExtractorViewModel
    /// 右栏可用高度（来自 GeometryReader）。DisclosureGroup 展开内容拒绝被
    /// 压缩到理想高度以下，必须用它显式钳住参数页的高度上限。
    var availableHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            SettingsPanel(model: model,
                          isExpanded: $model.settingsExpanded,
                          maxContentHeight: max(200, availableHeight - 44))
            // 展开参数时右栏整体让位给参数页：参数内容约 700pt，比面板高，
            // 若和字幕列表同屏显示，两个可滚动区域会互相争抢高度——之前就是
            // 列表被挤到 0 高、参数又被裁掉，整栏都滚不动。收起即回到列表。
            if !model.settingsExpanded {
                Divider()
                SubtitleListView(model: model)
            }
        }
        .background(Theme.surface)
    }
}
