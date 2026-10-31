import Foundation
import COnnxRuntime

enum OnnxError: LocalizedError {
    case unavailable(String)
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .inference(let message):
            return message
        }
    }
}

/// onnxruntime 会话的轻量封装。单输入、单输出、float32。
final class OnnxSession {
    private var handle: OpaquePointer?
    let modelPath: String
    private(set) var inputName = ""
    private(set) var outputName = ""

    init(modelPath: String) throws {
        self.modelPath = modelPath

        var error = [CChar](repeating: 0, count: 512)
        let created: OpaquePointer? = modelPath.withCString { path in
            hs_session_create(path, &error, 512)
        }
        guard let created else {
            throw OnnxError.unavailable(Self.message(from: error))
        }
        handle = created

        var inputBuffer = [CChar](repeating: 0, count: 256)
        var outputBuffer = [CChar](repeating: 0, count: 256)
        _ = hs_session_io_names(created, &inputBuffer, 256, &outputBuffer, 256)
        inputName = Self.message(from: inputBuffer)
        outputName = Self.message(from: outputBuffer)
    }

    deinit {
        if let handle {
            hs_session_destroy(handle)
        }
    }

    /// 运行时 onnxruntime 版本，不可用时返回 "unavailable"
    static var runtimeVersion: String {
        String(cString: hs_ort_version())
    }

    func run(input: [Float], shape: [Int]) throws -> (data: [Float], shape: [Int]) {
        guard let handle else { throw OnnxError.inference("会话已释放") }

        var error = [CChar](repeating: 0, count: 512)
        var outputData: UnsafeMutablePointer<Float>?
        var outputShape: UnsafeMutablePointer<Int64>?
        var outputDims: Int32 = 0
        let dimensions = shape.map(Int64.init)

        let ok: Int32 = input.withUnsafeBufferPointer { inputPointer in
            dimensions.withUnsafeBufferPointer { shapePointer in
                hs_session_run(handle,
                               inputPointer.baseAddress,
                               shapePointer.baseAddress,
                               Int32(dimensions.count),
                               &outputData,
                               &outputShape,
                               &outputDims,
                               &error,
                               512)
            }
        }

        guard ok == 1, let outputData, let outputShape else {
            throw OnnxError.inference(Self.message(from: error))
        }
        defer {
            hs_free(UnsafeMutableRawPointer(outputData))
            hs_free(UnsafeMutableRawPointer(outputShape))
        }

        var dims: [Int] = []
        var count = 1
        for index in 0..<Int(outputDims) {
            let dimension = Int(outputShape[index])
            dims.append(dimension)
            count *= dimension
        }

        let data = Array(UnsafeBufferPointer(start: outputData, count: max(1, count)))
        return (data, dims)
    }

    private static func message(from buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
    }
}
