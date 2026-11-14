import Foundation

/// 提取过程的磁盘流水账（JSONL）：观测结果一条一条即时落盘。
///
/// 为什么需要它——观测全攒内存、只在最后落盘的设计，进程被杀（手动停止、
/// 崩溃、断电）就什么都不剩。这是从 VSE 逆向里直接抄来的教训：它把 OCR
/// 结果攒在子进程内存、只在 finally 落盘，中途杀掉应用就丢掉全部已识别
/// 内容（其 issue #481「後半部字幕丟失」的成因之一）。
/// 本项目的对应做法：观测一产生就追加写盘并 fsync，之后无论怎么中断，
/// 都能从磁盘聚合出部分结果。
///
/// 文件格式（JSONL，UTF-8）：
///   第 1 行    SpoolHeader——锚点定义 + 时长。恢复聚合时不需要重新扫片头。
///   第 2 行起  每行一条 OCRObservation。
struct SpoolHeader: Codable {
    var anchors: [SubtitleAnchor]
    var totalDuration: Double
    var createdAt: Date
}

/// 非并发安全的设计约束：写入只发生在引擎的提取任务里；
/// 关闭/读取发生在引擎结束（或 ViewModel 取消）之后。
/// 用锁把 append 与 closeAndRemove 串起来，容忍「引擎还在收尾、
/// 用户已点停止」的竞态——所有操作幂等。
final class ExtractionSpool: @unchecked Sendable {

    /// 实际落盘位置（视频同目录，或降级到应用支持目录）
    let url: URL

    private let fileHandle: FileHandle
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var closed = false

    private init(url: URL, fileHandle: FileHandle) {
        self.url = url
        self.fileHandle = fileHandle
    }

    // MARK: - 创建

    /// 为一次提取创建 spool。优先放在视频同目录（`.hsub-partial.jsonl`，
    /// 用户找得到也删得掉）；目录不可写（只读卷、无权限）则降级到应用支持目录。
    /// 两个位置都失败返回 nil——提取照常进行，只是没有断点保护。
    static func create(forVideo videoURL: URL,
                       anchors: [SubtitleAnchor],
                       totalDuration: Double) -> ExtractionSpool? {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        var candidates: [URL] = []
        let primary = videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).hsub-partial.jsonl")
        candidates.append(primary)
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("HardSubExtractor/spool", isDirectory: true)
            candidates.append(dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).jsonl"))
        }

        for candidate in candidates {
            let directory = candidate.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            let directoryExists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            if !directoryExists || !isDirectory.boolValue {
                // 主位置目录不存在就放弃，降级位置则尝试建目录
                if candidate == primary { continue }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // 残留的旧 spool 直接覆盖：重新提取就是新一轮
            try? FileManager.default.removeItem(at: candidate)
            guard FileManager.default.createFile(atPath: candidate.path, contents: nil) else { continue }
            guard let handle = try? FileHandle(forWritingTo: candidate) else { continue }

            let spool = ExtractionSpool(url: candidate, fileHandle: handle)
            let header = SpoolHeader(anchors: anchors, totalDuration: totalDuration, createdAt: Date())
            spool.writeLine(header)
            return spool
        }
        return nil
    }

    /// 载入视频时查找同视频的残留 spool（上次中断留下的）
    static func findSpool(forVideo videoURL: URL) -> URL? {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let primary = videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).hsub-partial.jsonl")
        return FileManager.default.fileExists(atPath: primary.path) ? primary : nil
    }

    // MARK: - 写入

    func append(_ observation: OCRObservation) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        writeLine(observation)
    }

    /// 结束并删除流水账（正常完成、或恢复完成后调用）
    func closeAndRemove() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        closed = true
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// 只关闭、保留文件（手动取消时留给恢复流程）
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? fileHandle.close()
    }

    /// 单行写入并 fsync。观测只在行变化时产生（低频），逐条 fsync 的开销可忽略；
    /// 换来的承诺是断电后最多丢最后一条观测。
    private func writeLine(_ value: some Codable) {
        guard let data = try? encoder.encode(value) else { return }
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        fileHandle.write(Data([0x0A]))  // \n
        fileHandle.synchronizeFile()
    }

    // MARK: - 读取

    /// 读回整个流水账。首行解析不出 header（文件被截断）返回 nil。
    static func readContents(from url: URL) -> (header: SpoolHeader, observations: [OCRObservation])? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return nil }
        guard let header = try? JSONDecoder().decode(SpoolHeader.self, from: Data(first.utf8)) else { return nil }
        lines.removeFirst()

        let decoder = JSONDecoder()
        var observations: [OCRObservation] = []
        observations.reserveCapacity(lines.count)
        for line in lines {
            if let observation = try? decoder.decode(OCRObservation.self, from: Data(line.utf8)) {
                observations.append(observation)
            }
        }
        return (header, observations)
    }
}
