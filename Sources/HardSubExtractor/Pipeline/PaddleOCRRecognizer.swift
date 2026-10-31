import Foundation
import CoreVideo
import CoreGraphics

/// PaddleOCR（PP-OCRv3/v4）的 ONNX 实现：DBNet 文本检测 + SVTR-LCNet 文字识别。
///
/// 与 Vision 走同一个 `SubtitleRecognizer` 协议，所以聚合、时间轴、导出、UI 都不用改。
///
/// 依赖三样外部资源，都放在 `Resources/Models/`：
///   ch_PP-OCRv3_det_infer.onnx   DBNet 文本检测
///   ch_PP-OCRv3_rec_infer.onnx   SVTR 文字识别
///   ppocr_keys_v1.txt            6623 行字符字典
/// 以及 `Vendor/onnxruntime/lib/libonnxruntime.1.dylib`。
///
/// 动态库通过 dlopen 运行时加载，缺库时本识别器会报告不可用，应用其余部分不受影响。
final class PaddleOCRRecognizer: SubtitleRecognizer, @unchecked Sendable {

    struct Config {
        /// det 概率图二值化阈值
        var detThreshold: Float = 0.30
        /// 文本框平均置信度下限
        var boxThreshold: Float = 0.55
        /// unclip 膨胀系数，越大框越松
        var unclipRatio: Float = 1.60
        /// 过滤掉过小的连通域
        var minComponentPixels: Int = 6
        /// det 输入最长边
        var maxSideLimit: Int = 1280
        /// rec 输入高度，模型固定 48
        var recHeight: Int = 48
        /// rec 输入最大宽度，模型固定 320
        var recMaxWidth: Int = 320
        /// rec 置信度下限
        var recMinScore: Float = 0.35
        /// 是否把同一水平线上的框合并成一行
        var mergeLines: Bool = true
    }

    var config: Config
    private let explicitModelDirectory: URL?

    /// 调试钩子，命令行 --probe 会接上它输出中间量
    var debugLog: ((String) -> Void)?

    private var detSession: OnnxSession?
    private var recSession: OnnxSession?
    private var decodeTable: [String] = []
    private var prepareError: String?
    private var prepared = false
    private let lock = NSLock()

    init(modelDirectory: URL? = nil, config: Config = Config()) {
        self.explicitModelDirectory = modelDirectory
        self.config = config
    }

    // MARK: - 协议

    var displayName: String { "PaddleOCR (ONNX)" }

    var isAvailable: Bool {
        resolveModels() != nil && OnnxSession.runtimeVersion != "unavailable"
    }

    var unavailableReason: String? {
        if let models = resolveModels() { _ = models; return nil }
        if OnnxSession.runtimeVersion == "unavailable" {
            return "找不到 libonnxruntime.1.dylib。请确认 Vendor/onnxruntime/lib/ 下存在该文件，或设置环境变量 HS_ONNXRUNTIME_PATH。"
        }
        guard let directory = modelDirectory() else {
            return "找不到模型目录。请把 det / rec / keys 放到 Resources/Models/ 下。"
        }
        let missing = missingFiles(in: directory)
        if !missing.isEmpty {
            return "模型目录 \(directory.path) 缺少：\(missing.joined(separator: "、"))"
        }
        return "PaddleOCR 初始化失败"
    }

    var statusDescription: String {
        guard let models = resolveModels() else {
            return "onnxruntime \(OnnxSession.runtimeVersion) · 模型未就绪"
        }
        return "onnxruntime \(OnnxSession.runtimeVersion) · \(models.rec.lastPathComponent)"
    }

    func recognize(pixelBuffer: CVPixelBuffer) async throws -> [RecognizedLine] {
        try prepare()
        guard let detSession, let recSession else {
            throw RecognizerError.unavailable(prepareError ?? "PaddleOCR 未就绪")
        }
        guard let image = BGRAImage(pixelBuffer: pixelBuffer) else {
            throw RecognizerError.failed("像素格式不受支持（需要 32BGRA）")
        }

        let boxes = try detectText(in: image, session: detSession)
        guard !boxes.isEmpty else { return [] }

        var lines: [RecognizedLine] = []
        for box in boxes {
            guard let recognized = try? recognizeLine(in: image, box: box, session: recSession) else { continue }
            guard !recognized.text.isEmpty, recognized.score >= Double(config.recMinScore) else { continue }
            let normalized = CGRect(x: box.minX / CGFloat(image.width),
                                    y: 1 - box.maxY / CGFloat(image.height),
                                    width: box.width / CGFloat(image.width),
                                    height: box.height / CGFloat(image.height))
            lines.append(RecognizedLine(text: recognized.text,
                                        confidence: recognized.score,
                                        boundingBox: normalized))
        }

        lines.sort { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.02 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return lines
    }

    // MARK: - 初始化

    private func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        if prepared {
            if let prepareError { throw RecognizerError.unavailable(prepareError) }
            return
        }
        prepared = true

        guard let models = resolveModels() else {
            prepareError = unavailableReason ?? "PaddleOCR 不可用"
            throw RecognizerError.unavailable(prepareError!)
        }

        do {
            detSession = try OnnxSession(modelPath: models.det.path)
            recSession = try OnnxSession(modelPath: models.rec.path)
            let characters = try loadKeys(from: models.keys)
            var table: [String] = [""]
            table.append(contentsOf: characters)
            if table.count < 6625 { table.append(" ") }
            decodeTable = table
        } catch {
            prepareError = error.localizedDescription
            throw RecognizerError.unavailable(prepareError!)
        }
    }

    private func loadKeys(from url: URL) throws -> [String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: - 模型发现

    private func modelDirectory() -> URL? {
        if let explicitModelDirectory { return explicitModelDirectory }

        if let env = ProcessInfo.processInfo.environment["HS_PADDLE_MODELS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }

        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("Resources/Models"))
            candidates.append(directory.appendingPathComponent("../Resources/Models"))
            candidates.append(directory.appendingPathComponent("../../Resources/Models"))
            candidates.append(directory.appendingPathComponent("../../../Resources/Models"))
        }
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("Models"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HardSubExtractor/models"))

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func missingFiles(in directory: URL) -> [String] {
        let names = ["ch_PP-OCRv3_det_infer.onnx", "ch_PP-OCRv3_rec_infer.onnx", "ppocr_keys_v1.txt"]
        return names.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private func resolveModels() -> (det: URL, rec: URL, keys: URL)? {
        guard let directory = modelDirectory() else { return nil }

        // v3 优先：实测在 360p 小字上 v3 全对、v4 会把「一」读成「→」并切碎行，
        // 720p 上两者打平。v3 体积也更小。想用 v4 把文件放进模型目录即可。
        let detNames = ["ch_PP-OCRv3_det_infer.onnx", "ch_PP-OCRv4_det_infer.onnx", "det.onnx"]
        let recNames = ["ch_PP-OCRv3_rec_infer.onnx", "ch_PP-OCRv4_rec_infer.onnx", "rec.onnx"]
        let keyNames = ["ppocr_keys_v1.txt", "keys.txt"]

        func first(_ names: [String]) -> URL? {
            for name in names {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }

        guard let det = first(detNames), let rec = first(recNames), let keys = first(keyNames) else {
            return nil
        }
        return (det, rec, keys)
    }

    // MARK: - 文本检测

    private func detectText(in image: BGRAImage, session: OnnxSession) throws -> [CGRect] {
        let maxSide = Float(config.maxSideLimit)
        let sourceWidth = Float(image.width)
        let sourceHeight = Float(image.height)
        guard sourceWidth > 8, sourceHeight > 8 else { return [] }

        let scale = min(1, maxSide / max(sourceWidth, sourceHeight))
        let resizedWidth = max(32, Int((sourceWidth * scale).rounded()))
        let resizedHeight = max(32, Int((sourceHeight * scale).rounded()))
        let canvasWidth = ((resizedWidth + 31) / 32) * 32
        let canvasHeight = ((resizedHeight + 31) / 32) * 32

        let input = image.normalizedCHW(sourceRect: CGRect(x: 0, y: 0,
                                                          width: image.width, height: image.height),
                                        targetWidth: resizedWidth,
                                        targetHeight: resizedHeight,
                                        canvasWidth: canvasWidth,
                                        canvasHeight: canvasHeight,
                                        mean: (0.485, 0.456, 0.406),
                                        std: (0.229, 0.224, 0.225))

        let (probability, shape) = try session.run(input: input,
                                                   shape: [1, 3, canvasHeight, canvasWidth])
        guard shape.count >= 4 else { return [] }
        let outHeight = shape[shape.count - 2]
        let outWidth = shape[shape.count - 1]
        guard probability.count >= outWidth * outHeight else { return [] }

        let components = connectedComponents(probability,
                                             width: outWidth,
                                             height: outHeight,
                                             threshold: config.detThreshold)

        let peak = probability.max() ?? 0
        let mean = probability.isEmpty ? 0 : probability.reduce(0, +) / Float(probability.count)
        debugLog?("det: input \(canvasWidth)x\(canvasHeight) → output \(outWidth)x\(outHeight), "
                  + String(format: "prob max=%.3f mean=%.4f, 连通域=%d", peak, mean, components.count))

        let mapX = sourceWidth / Float(resizedWidth)
        let mapY = sourceHeight / Float(resizedHeight)
        var boxes: [CGRect] = []

        for component in components {
            guard component.count >= config.minComponentPixels else { continue }
            let score = component.sum / Float(component.count)
            guard score >= config.boxThreshold else { continue }

            var x0 = Float(component.minX)
            var y0 = Float(component.minY)
            var x1 = Float(component.maxX + 1)
            var y1 = Float(component.maxY + 1)

            let boxWidth = x1 - x0
            let boxHeight = y1 - y0
            let perimeter = 2 * (boxWidth + boxHeight)
            guard perimeter > 0 else { continue }

            let offset = (boxWidth * boxHeight) * config.unclipRatio / perimeter
            x0 -= offset
            y0 -= offset
            x1 += offset
            y1 += offset

            let rect = CGRect(x: CGFloat(x0 * mapX),
                              y: CGFloat(y0 * mapY),
                              width: CGFloat((x1 - x0) * mapX),
                              height: CGFloat((y1 - y0) * mapY))
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

            guard rect.width >= 4, rect.height >= 4 else { continue }
            boxes.append(rect)
        }

        debugLog?("det: 通过筛选的框 \(boxes.count) 个 → 合并后 \(config.mergeLines ? mergeIntoLines(boxes).count : boxes.count) 行")
        return config.mergeLines ? mergeIntoLines(boxes) : boxes.sorted { $0.minY < $1.minY }
    }

    private struct Component {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
        var count: Int
        var sum: Float
    }

    private func connectedComponents(_ probability: [Float],
                                     width: Int,
                                     height: Int,
                                     threshold: Float) -> [Component] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [Component] = []
        var stack: [Int] = []
        stack.reserveCapacity(1024)

        for startY in 0..<height {
            let rowBase = startY * width
            for startX in 0..<width {
                let startIndex = rowBase + startX
                if visited[startIndex] { continue }
                visited[startIndex] = true
                if probability[startIndex] <= threshold { continue }

                stack.removeAll(keepingCapacity: true)
                stack.append(startIndex)

                var component = Component(minX: startX, minY: startY,
                                          maxX: startX, maxY: startY,
                                          count: 0, sum: 0)

                while let index = stack.popLast() {
                    let y = index / width
                    let x = index % width
                    component.count += 1
                    component.sum += probability[index]
                    if x < component.minX { component.minX = x }
                    if x > component.maxX { component.maxX = x }
                    if y < component.minY { component.minY = y }
                    if y > component.maxY { component.maxY = y }

                    for dy in -1...1 {
                        let ny = y + dy
                        if ny < 0 || ny >= height { continue }
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            let nx = x + dx
                            if nx < 0 || nx >= width { continue }
                            let neighbor = ny * width + nx
                            if visited[neighbor] { continue }
                            visited[neighbor] = true
                            if probability[neighbor] > threshold { stack.append(neighbor) }
                        }
                    }
                }
                components.append(component)
            }
        }
        return components
    }

    /// 把同一水平线上的碎片框拼成整行，DBNet 对细笔画偶尔会断开
    private func mergeIntoLines(_ boxes: [CGRect]) -> [CGRect] {
        guard !boxes.isEmpty else { return [] }
        var lines: [CGRect] = []

        for box in boxes.sorted(by: { $0.minY < $1.minY }) {
            var merged = false
            for index in lines.indices {
                let line = lines[index]
                let overlap = min(line.maxY, box.maxY) - max(line.minY, box.minY)
                let minHeight = min(line.height, box.height)
                guard minHeight > 0, overlap / minHeight > 0.5 else { continue }

                let gap = max(0, max(box.minX - line.maxX, line.minX - box.maxX))
                guard gap < max(line.height, box.height) * 0.8 else { continue }

                lines[index] = line.union(box)
                merged = true
                break
            }
            if !merged { lines.append(box) }
        }
        return lines.sorted { $0.minY < $1.minY }
    }

    // MARK: - 文字识别

    private func recognizeLine(in image: BGRAImage,
                               box: CGRect,
                               session: OnnxSession) throws -> (text: String, score: Double) {
        let rect = box.integral
        guard rect.width >= 2, rect.height >= 2 else { return ("", 0) }

        let targetHeight = config.recHeight
        let rawWidth = rect.width / rect.height * CGFloat(targetHeight)
        let targetWidth = min(max(Int(rawWidth.rounded()), 16), config.recMaxWidth)

        let input = image.normalizedCHW(sourceRect: rect,
                                        targetWidth: targetWidth,
                                        targetHeight: targetHeight,
                                        canvasWidth: config.recMaxWidth,
                                        canvasHeight: targetHeight,
                                        mean: (0.5, 0.5, 0.5),
                                        std: (0.5, 0.5, 0.5))

        let (logits, shape) = try session.run(input: input,
                                              shape: [1, 3, targetHeight, config.recMaxWidth])
        guard shape.count >= 3 else { return ("", 0) }

        let timeSteps = shape[shape.count - 2]
        let classCount = shape[shape.count - 1]
        guard classCount > 1, logits.count >= timeSteps * classCount else { return ("", 0) }

        var characters: [String] = []
        var scores: [Float] = []
        var previous = -1

        for step in 0..<timeSteps {
            let offset = step * classCount

            var bestIndex = 0
            var bestValue = logits[offset]
            for c in 1..<classCount where logits[offset + c] > bestValue {
                bestValue = logits[offset + c]
                bestIndex = c
            }

            // PP-OCR 导出的 rec 模型末端已经带 softmax，输出就是概率；
            // 但不同版本的导出方式不一致，用取值范围判断一下，避免多算或漏算。
            let probability: Float
            if bestValue > 1.0 || bestValue < 0 {
                var sum: Float = 0
                for c in 0..<classCount {
                    sum += exp(logits[offset + c] - bestValue)
                }
                probability = 1 / max(sum, 1e-6)
            } else {
                probability = bestValue
            }

            if bestIndex != 0 && bestIndex != previous && bestIndex < decodeTable.count {
                characters.append(decodeTable[bestIndex])
                scores.append(probability)
            }
            previous = bestIndex
        }

        let text = characters.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let score = scores.isEmpty ? 0 : Double(scores.reduce(0, +) / Float(scores.count))
        debugLog?(String(format: "rec: box=%.0fx%.0f → T=%d C=%d 文本=「%@」分数=%.3f",
                         rect.width, rect.height, timeSteps, classCount, text, score))
        return (text, score)
    }
}
