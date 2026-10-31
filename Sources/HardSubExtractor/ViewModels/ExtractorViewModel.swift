import Foundation
import AVFoundation
import Observation
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class ExtractorViewModel {

    // MARK: - 媒体

    var videoURL: URL?
    var player: AVPlayer?
    var currentTime: Double = 0
    var videoDuration: Double = 0
    var videoAspect: CGFloat = 16.0 / 9.0
    var videoResolution: String = ""
    var videoCodec: String = ""
    /// 导入体检发现的问题；非空时不允许开始提取
    var videoProblem: String?
    /// 体检进行中
    var isProbing = false
    /// 体检选定的解码器
    var decoderKind: VideoDecoderKind = .auto

    // MARK: - 预览（FFmpeg 兜底模式）
    //
    // AVPlayer 解不了的文件（MKV / 10-bit H.264 / AV1）用抽帧预览代替播放：
    // 拖到哪儿就显示那一帧，够用来对位字幕区域。

    var previewImage: CGImage?
    var previewLoading = false
    private var previewTask: Task<Void, Never>?

    /// 当前是否在用抽帧预览（而不是真正的播放器）
    var isFallbackPreview: Bool { decoderKind == .ffmpeg }

    func requestPreview(at time: Double) {
        guard let url = videoURL, isFallbackPreview else { return }
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            // 拖动时合并请求，别每一像素都起一个 ffmpeg
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.previewLoading = true

            let frame = await Task.detached(priority: .userInitiated) { () -> PreviewFrame? in
                guard let image = FFmpegFrameExtractor.frame(url: url, time: time) else { return nil }
                return PreviewFrame(image: image)
            }.value

            guard !Task.isCancelled else { return }
            if let frame { self.previewImage = frame.image }
            self.previewLoading = false
        }
    }

    /// CGImage 不是 Sendable，包一层好跨线程传
    private struct PreviewFrame: @unchecked Sendable {
        let image: CGImage
    }

    /// 文件选择器是否弹出（由菜单命令和按钮共同驱动）
    var isImporterPresented = false

    // MARK: - 结果与状态

    var segments: [SubtitleSegment] = []
    var isRunning = false
    var progress: Double = 0
    var statusText = "导入视频后点击「开始提取」"
    var errorMessage: String?
    var analyzedFrameCount = 0

    // MARK: - 参数
    //
    // 全部持久化到 UserDefaults：关窗重开不用重调。didSet 里写盘，拖滑杆的
    // 连续回调也只是几十次轻量写入。

    /// 字幕搜索区域：自动找字幕行时在这块范围里找
    var roiTop: Double = 0.58 { didSet { persistPreferences() } }
    var roiBottom: Double = 1.0 { didSet { persistPreferences() } }
    var roiLeft: Double = 0.02 { didSet { persistPreferences() } }
    var roiRight: Double = 0.98 { didSet { persistPreferences() } }

    /// 采样帧率
    var sampleFPS: Double = 10 { didSet { persistPreferences() } }
    var hashThreshold: Double = 4 { didSet { persistPreferences() } }
    var upscale: Double = 1.6 { didSet { persistPreferences() } }
    /// 一行发生变化后重复识别几帧来投票。1 = 最快，3 = 最稳。
    var voteFrames: Double = 3 { didSet { persistPreferences() } }

    var useSimplifiedChinese = true { didSet { persistPreferences() } }
    var useTraditionalChinese = false { didSet { persistPreferences() } }
    var useEnglish = true { didSet { persistPreferences() } }
    var usesLanguageCorrection = true { didSet { persistPreferences() } }

    var engine: OCREngine = .vision { didSet { persistPreferences() } }
    var filterWatermarks = true { didSet { persistPreferences() } }
    /// 最近一次导出用的格式，⌘E 绑定在它上面
    var lastExportFormat: ExportFormat = .srt { didSet { persistPreferences() } }

    var showsROIOverlay = true { didSet { persistPreferences() } }

    /// 参数面板是否展开。放模型里而不是视图本地状态，
    /// 是为了 --settings 启动参数和菜单命令都能驱动它。
    var settingsExpanded = false

    /// ROI 拖拽调整模式：暂停播放、用当前帧的静态图替换播放器。
    /// AVPlayerView（AppKit 桥接）会吞掉上方 SwiftUI 手势的鼠标事件，
    /// 静态 Image 上手势才可达；调整完恢复播放器。
    var isAdjustingROI = false
    var roiAdjustImage: CGImage?
    @ObservationIgnored private var roiAdjustTask: Task<Void, Never>?

    /// 自动检测出的字幕行。为空时提取会退化成用搜索区域当一条锚点。
    var anchors: [SubtitleAnchor] = []
    /// 当前阶段文案（分析字幕 / 提取字幕）
    var phaseText = ""

    /// 导出成功后的文件位置，状态条提供「在 Finder 中显示」
    var exportedURL: URL?

    private var runTask: Task<Void, Never>?
    private var timeObserver: Any?
    /// timeObserver 注册在哪个 player 上——token 必须从注册它的实例移除
    private var timeObserverPlayer: AVPlayer?
    /// 已申请安全作用域访问的 URL，载入新文件时配对释放
    private var securityScopedURL: URL?
    private var memoryLogger: Task<Void, Never>?
    /// 提取阶段开始时间，用于 ETA 估算
    @ObservationIgnored private var extractionStartedAt: Date?

    init() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "engine"), let saved = OCREngine(rawValue: raw) {
            engine = saved
        }
        useSimplifiedChinese = d.object(forKey: "useSimplifiedChinese") as? Bool ?? true
        useTraditionalChinese = d.object(forKey: "useTraditionalChinese") as? Bool ?? false
        useEnglish = d.object(forKey: "useEnglish") as? Bool ?? true
        usesLanguageCorrection = d.object(forKey: "usesLanguageCorrection") as? Bool ?? true
        filterWatermarks = d.object(forKey: "filterWatermarks") as? Bool ?? true
        sampleFPS = d.object(forKey: "sampleFPS") as? Double ?? 10
        hashThreshold = d.object(forKey: "hashThreshold") as? Double ?? 4
        upscale = d.object(forKey: "upscale") as? Double ?? 1.6
        voteFrames = d.object(forKey: "voteFrames") as? Double ?? 3
        roiTop = d.object(forKey: "roiTop") as? Double ?? 0.58
        roiBottom = d.object(forKey: "roiBottom") as? Double ?? 1.0
        roiLeft = d.object(forKey: "roiLeft") as? Double ?? 0.02
        roiRight = d.object(forKey: "roiRight") as? Double ?? 0.98
        showsROIOverlay = d.object(forKey: "showsROIOverlay") as? Bool ?? true
        if let raw = d.string(forKey: "lastExportFormat"), let saved = ExportFormat(rawValue: raw) {
            lastExportFormat = saved
        }
    }

    private func persistPreferences() {
        let d = UserDefaults.standard
        d.set(engine.rawValue, forKey: "engine")
        d.set(useSimplifiedChinese, forKey: "useSimplifiedChinese")
        d.set(useTraditionalChinese, forKey: "useTraditionalChinese")
        d.set(useEnglish, forKey: "useEnglish")
        d.set(usesLanguageCorrection, forKey: "usesLanguageCorrection")
        d.set(filterWatermarks, forKey: "filterWatermarks")
        d.set(sampleFPS, forKey: "sampleFPS")
        d.set(hashThreshold, forKey: "hashThreshold")
        d.set(upscale, forKey: "upscale")
        d.set(voteFrames, forKey: "voteFrames")
        d.set(roiTop, forKey: "roiTop")
        d.set(roiBottom, forKey: "roiBottom")
        d.set(roiLeft, forKey: "roiLeft")
        d.set(roiRight, forKey: "roiRight")
        d.set(showsROIOverlay, forKey: "showsROIOverlay")
        d.set(lastExportFormat.rawValue, forKey: "lastExportFormat")
    }

    /// 供界面查询 PaddleOCR 状态用；避免每次渲染都新建识别器
    private let paddleProbe = PaddleOCRRecognizer()

    var paddleAvailable: Bool { paddleProbe.isAvailable }

    /// 设置 HS_DEBUG_MEMORY=1 时每 2 秒把内存占用打到 stderr，用于排查泄漏
    private func startMemoryLoggingIfNeeded() {
        guard ProcessInfo.processInfo.environment["HS_DEBUG_MEMORY"] == "1",
              memoryLogger == nil else { return }
        memoryLogger = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let line = "[mem] \(MemoryProbe.describe()) 帧=\(self.analyzedFrameCount)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    // MARK: - 派生值

    var roi: CGRect {
        let left = min(roiLeft, roiRight - 0.05)
        let right = max(roiRight, left + 0.05)
        let top = min(roiTop, roiBottom - 0.05)
        let bottom = max(roiBottom, top + 0.05)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    var exportableSegments: [SubtitleSegment] {
        filterWatermarks ? segments.filter { !$0.isSuspectedWatermark } : segments
    }

    var watermarkCount: Int {
        segments.filter(\.isSuspectedWatermark).count
    }

    var hasVideo: Bool { videoURL != nil }

    /// 有视频、没在跑、且体检通过
    var canStart: Bool { hasVideo && !isRunning && !isProbing && videoProblem == nil }

    var displayName: String {
        videoURL?.deletingPathExtension().lastPathComponent ?? "未载入视频"
    }

    var subtitleCoverage: TimeInterval {
        segments.filter { !$0.isSuspectedWatermark }.reduce(0) { $0 + $1.duration }
    }

    /// 当前引擎的一句话状态，显示在参数面板里
    var engineStatusText: String {
        switch engine {
        case .vision:
            return "系统内置，无需额外模型和依赖"
        case .paddle:
            if paddleProbe.isAvailable {
                return paddleProbe.statusDescription
            }
            return paddleProbe.unavailableReason ?? "PaddleOCR 不可用"
        }
    }

    var currentSegment: SubtitleSegment? {
        segments.first { $0.contains(currentTime) && !$0.isBlank }
    }

    // MARK: - 载入

    func load(url: URL) {
        runTask?.cancel()
        runTask = nil
        isRunning = false

        // 释放上一次的安全作用域再申请新的。返回 false 说明不是安全作用域 URL
        // （比如拖拽进来的普通文件），不需要配对释放。
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        videoURL = url
        segments = []
        analyzedFrameCount = 0
        progress = 0
        errorMessage = nil
        undoStack.removeAll()
        lastModified = .distantPast
        lastExported = .distantPast
        exportedURL = nil
        extractionStartedAt = nil
        endROIAdjust()
        currentTime = 0
        videoDuration = 0
        videoAspect = 16.0 / 9.0
        videoResolution = ""
        anchors = []
        phaseText = ""
        videoCodec = ""
        videoProblem = nil
        previewImage = nil
        previewLoading = false
        previewTask?.cancel()
        isProbing = true
        statusText = "已载入，可以开始提取"

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        attachTimeObserver(to: newPlayer)
        startMemoryLoggingIfNeeded()

        Task { @MainActor [weak self] in
            let result = await VideoProbe.probe(url: url)
            guard let self, self.videoURL == url else { return }
            self.isProbing = false
            if result.duration > 0 { self.videoDuration = result.duration }
            if result.naturalSize.width > 0, result.naturalSize.height > 0 {
                self.videoAspect = result.naturalSize.width / result.naturalSize.height
                self.videoResolution = "\(Int(result.naturalSize.width))×\(Int(result.naturalSize.height))"
            }
            self.videoCodec = result.codec
            self.videoProblem = result.problem
            self.decoderKind = result.decoder
            if let problem = result.problem {
                self.statusText = "这个视频解不了"
                self.errorMessage = problem
            } else if let note = result.note {
                self.statusText = note
            }
            if result.decoder == .ffmpeg {
                self.requestPreview(at: 0)
            }
        }
    }

    private func attachTimeObserver(to player: AVPlayer) {
        // token 必须从注册它的那个 player 实例上移除；以前误用新 player 来移除
        // 旧 player 的 token，跨实例调用属于未定义行为，旧观察器也从未被真正移除
        if let timeObserver, let timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObserverPlayer = nil

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
    }

    // MARK: - 提取

    func start() {
        guard let url = videoURL else {
            errorMessage = "请先导入一个视频文件"
            return
        }
        guard !isRunning else { return }

        // 导入体检已经判定解不了，就别让用户白等一轮
        if let problem = videoProblem {
            errorMessage = problem
            return
        }

        let recognizer = makeRecognizer()
        guard recognizer.isAvailable else {
            errorMessage = recognizer.unavailableReason ?? "当前识别引擎不可用"
            return
        }

        // 提取时暂停播放：画面静止才看得清 ROI 框对没对准，也省一份解码开销
        player?.pause()
        endROIAdjust()

        segments = []
        analyzedFrameCount = 0
        progress = 0
        errorMessage = nil
        undoStack.removeAll()
        exportedURL = nil
        isRunning = true

        // PaddleOCR 的 rec 会把文本框统一缩放到 48 高，外层再放大没有收益，
        // 反而让 det 多算一遍；Vision 则确实受益于放大。
        let effectiveUpscale: CGFloat = engine == .paddle ? 1.0 : upscale
        let searchROI = roi

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 第一阶段：没检测过锚点就先扫一遍片头，找出字幕行
            if self.anchors.isEmpty {
                self.phaseText = "分析字幕"
                self.statusText = "正在定位字幕行…"
                var detection = AnchorDetectionConfig(searchROI: searchROI)
                detection.decoder = self.decoderKind
                let result = try? await AnchorDetector.detect(url: url,
                                                              config: detection,
                                                              recognizer: recognizer) { [weak self] value, text in
                    Task { @MainActor in
                        self?.progress = value * 0.25
                        self?.statusText = text
                    }
                }
                self.anchors = result?.anchors ?? []
                if self.anchors.isEmpty {
                    self.statusText = "没找到固定字幕行，退回整块区域识别"
                }
            }

            guard !Task.isCancelled else { self.isRunning = false; return }

            // 第二阶段：按锚点逐行提取
            self.phaseText = "提取字幕"
            self.statusText = "正在解码视频…"
            self.progress = 0.25
            self.extractionStartedAt = Date()

            let config = ExtractionConfig(roi: searchROI,
                                          anchors: self.anchors,
                                          fps: self.sampleFPS,
                                          hashThreshold: Int(self.hashThreshold),
                                          upscale: effectiveUpscale,
                                          decoder: self.decoderKind,
                                          totalDuration: self.videoDuration,
                                          voteFrames: Int(self.voteFrames))

            let stream = ExtractionEngine.run(url: url, config: config, recognizer: recognizer)

            for await event in stream {
                switch event {
                case .progress(let value, let text):
                    self.progress = 0.25 + value * 0.75
                    self.statusText = self.etaText(for: value, baseText: text)
                case .observation:
                    self.analyzedFrameCount += 1
                case .finished(let result, let completed, let note):
                    self.segments = result
                    self.markModified()
                    if completed {
                        self.progress = 1
                    }
                    self.statusText = note
                    self.phaseText = ""
                    self.extractionStartedAt = nil
                case .failed(let message):
                    self.errorMessage = "「\(self.displayName)」\n\n\(message)"
                    self.statusText = "提取失败"
                    self.extractionStartedAt = nil
                }
            }
            self.isRunning = false
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        statusText = "已停止"
    }

    /// 重新检测字幕行：只跑锚点分析，不动已有的识别结果
    func redetectAnchors() {
        guard let url = videoURL, hasVideo, !isRunning, !isProbing else { return }
        let recognizer = makeRecognizer()
        guard recognizer.isAvailable else {
            errorMessage = recognizer.unavailableReason ?? "当前识别引擎不可用"
            return
        }

        anchors = []
        progress = 0
        isRunning = true
        phaseText = "分析字幕"
        statusText = "正在定位字幕行…"

        runTask = Task { @MainActor [weak self] in
            var detection = AnchorDetectionConfig(searchROI: self?.roi ?? CGRect(x: 0.02, y: 0.58, width: 0.96, height: 0.42))
            detection.decoder = self?.decoderKind ?? .auto
            let result = try? await AnchorDetector.detect(url: url,
                                                          config: detection,
                                                          recognizer: recognizer) { [weak self] value, text in
                Task { @MainActor in
                    self?.progress = value
                    self?.statusText = text
                }
            }
            guard let self else { return }
            self.anchors = result?.anchors ?? []
            self.isRunning = false
            self.phaseText = ""
            self.progress = 0
            self.statusText = self.anchors.isEmpty
                ? "没找到固定字幕行，提取时将使用整块搜索区域"
                : "已定位 \(self.anchors.count) 行字幕，可以开始提取"
        }
    }

    /// 视频 ROI 拖拽回写（AnchorOverlay 的手柄/移动手势调用）
    func updateROI(_ rect: CGRect) {
        roiTop = rect.minY
        roiBottom = rect.maxY
        roiLeft = rect.minX
        roiRight = rect.maxX
    }

    /// 进入 ROI 调整模式：暂停播放并抓取当前帧做静态底图。
    /// fallback 预览本身就是静态图，Overlay 已经可交互，直接返回。
    func beginROIAdjust() {
        guard hasVideo, !isRunning, !isAdjustingROI, let url = videoURL else { return }
        player?.pause()
        if isFallbackPreview { return }
        let time = currentTime
        isAdjustingROI = true
        roiAdjustImage = nil
        roiAdjustTask?.cancel()
        roiAdjustTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                await MainActor.run { self?.roiAdjustImage = image }
            } catch {
                await MainActor.run {
                    self?.isAdjustingROI = false
                    self?.errorMessage = "取帧失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func endROIAdjust() {
        roiAdjustTask?.cancel()
        isAdjustingROI = false
        roiAdjustImage = nil
    }

    /// 提取阶段的剩余时间估算（按进度线性外推）
    private func etaText(for value: Double, baseText: String) -> String {
        guard let started = extractionStartedAt, value > 0.02, value < 0.98 else { return baseText }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 2 else { return baseText }
        let remaining = elapsed / value * (1 - value)
        let text: String
        if remaining < 60 {
            text = "剩余约 \(Int(remaining.rounded(.up))) 秒"
        } else {
            text = "剩余约 \(Int((remaining / 60).rounded(.up))) 分钟"
        }
        return baseText + " · " + text
    }

    private func makeRecognizer() -> any SubtitleRecognizer {
        switch engine {
        case .vision:
            var languages: [String] = []
            if useSimplifiedChinese { languages.append("zh-Hans") }
            if useTraditionalChinese { languages.append("zh-Hant") }
            if useEnglish { languages.append("en-US") }
            return VisionRecognizer(languages: languages,
                                    usesLanguageCorrection: usesLanguageCorrection)
        case .paddle:
            return PaddleOCRRecognizer()
        }
    }

    // MARK: - 播放控制

    func seek(to time: TimeInterval) {
        currentTime = max(0, time)
        if isFallbackPreview {
            requestPreview(at: currentTime)
            return
        }
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 校对时从列表点进某一句：跳过去并暂停，方便听清这句
    func seekAndPause(to time: TimeInterval) {
        seek(to: time)
        player?.pause()
    }

    func togglePlayback() {
        guard let player, !isFallbackPreview else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// 跳到上一句字幕的起点。校对时反复听同一句是最高频操作，
    /// 播放器自带的控件做不到这个粒度。
    func seekToPreviousSegment() {
        let current = currentTime
        if let previous = segments.last(where: { $0.start < current - 0.15 }) {
            seek(to: previous.start)
        } else {
            seek(to: 0)
        }
    }

    func seekToNextSegment() {
        let current = currentTime
        if let next = segments.first(where: { $0.start > current + 0.15 }) {
            seek(to: next.start)
        }
    }

    // MARK: - 编辑（带撤销）
    //
    // 撤销采用整表快照：字幕段是小的值类型，几百条也只几百 KB，
    // 比逐条记录反向操作简单得多。文本编辑按「编辑会话」入栈——
    // 聚焦时登记、第一次真正改动才压栈，避免每个按键都占一格。

    @ObservationIgnored private var lastModified = Date.distantPast
    @ObservationIgnored private var lastExported = Date.distantPast
    @ObservationIgnored private var textEditUndoPending = false
    private var undoStack: [[SubtitleSegment]] = []

    var canUndo: Bool { !undoStack.isEmpty }

    /// 列表里有未导出的内容（识别结果或手动修改）时为真，用于退出确认
    var hasUnsavedChanges: Bool {
        !segments.isEmpty && lastModified > lastExported
    }

    private func markModified() {
        lastModified = Date()
    }

    private func pushUndo() {
        undoStack.append(segments)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }

    /// 文本编辑会话开始（行内输入框获得焦点）
    func beginTextEdit() {
        textEditUndoPending = true
    }

    /// 文本编辑会话结束；没有实际改动就不占撤销格
    func endTextEdit() {
        textEditUndoPending = false
    }

    func updateSegmentText(id: UUID, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        if textEditUndoPending {
            pushUndo()
            textEditUndoPending = false
        }
        segments[index].text = text
        markModified()
    }

    func updateSegmentTimes(id: UUID, start: Double, end: Double) {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              start.isFinite, end.isFinite else { return }
        pushUndo()
        let newStart = max(0, min(start, end - 0.05))
        let newEnd = max(newStart + 0.05, end)
        segments[index].start = newStart
        segments[index].end = newEnd
        markModified()
    }

    func removeSegment(id: UUID) {
        pushUndo()
        segments.removeAll { $0.id == id }
    }

    func removeBlankSegments() {
        pushUndo()
        segments.removeAll { $0.isBlank }
    }

    func deleteWatermarkSegments() {
        pushUndo()
        segments.removeAll { $0.isSuspectedWatermark }
    }

    /// 与时间轴上的下一条合并：文本换行拼接，时间段取并集
    func mergeWithNext(id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              index + 1 < segments.count else { return }
        pushUndo()
        let current = segments[index]
        let next = segments[index + 1]
        let joined: String
        if current.text.isEmpty {
            joined = next.text
        } else if next.text.isEmpty {
            joined = current.text
        } else {
            joined = current.text + "\n" + next.text
        }
        segments[index].text = joined
        segments[index].end = max(current.end, next.end)
        segments[index].confidence = max(current.confidence, next.confidence)
        segments.remove(at: index + 1)
        markModified()
    }

    func undoLastEdit() {
        guard let previous = undoStack.popLast() else { return }
        segments = previous
        markModified()
    }

    func resetSettings() {
        roiTop = 0.58
        roiBottom = 1.0
        roiLeft = 0.02
        roiRight = 0.98
        sampleFPS = 10
        hashThreshold = 4
        upscale = 1.6
        voteFrames = 3
        anchors = []
    }

    /// 丢掉已检测的字幕行，下次提取会重新扫描
    func clearAnchors() {
        anchors = []
        statusText = "已清除字幕行，下次提取会重新分析"
    }

    // MARK: - 导出

    func export(as format: ExportFormat) {
        let items = exportableSegments
        guard !items.isEmpty else {
            errorMessage = "没有可导出的字幕"
            return
        }
        lastExportFormat = format

        let content: String
        switch format {
        case .srt: content = SubtitleExporter.srt(items)
        case .vtt: content = SubtitleExporter.webVTT(items)
        case .txt: content = SubtitleExporter.plainText(items)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        let base = videoURL?.deletingPathExtension().lastPathComponent ?? "subtitle"
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    guard let self else { return }
                    self.lastExported = Date()
                    self.exportedURL = url
                    let filtered = self.filterWatermarks ? self.watermarkCount : 0
                    let suffix = filtered > 0 ? "（已过滤 \(filtered) 条疑似水印）" : ""
                    self.statusText = "已导出 \(url.lastPathComponent) · \(items.count) 条\(suffix)"
                }
            } catch {
                Task { @MainActor in
                    self?.errorMessage = "保存失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
