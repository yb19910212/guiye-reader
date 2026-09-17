import Foundation
import CryptoKit

enum OfflineModelFiles {
    static let revision = "0d6bb6fe33f92d47a507e23b9148940e8366ab5b"
    static let paths = ["model.safetensors", "speech_tokenizer/model.safetensors"]
    static func error(_ message: String) -> NSError {
        NSError(domain: "OfflineModelFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func sourceURL(path: String, source: String, custom: String) throws -> URL {
        guard paths.contains(path) else { throw error("不支持的模型文件") }
        let root: String
        switch source {
        case "official": root = "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit/resolve/\(revision)"
        case "mirror": root = "https://hf-mirror.com/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit/resolve/\(revision)"
        case "custom": root = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        default: throw error("请选择下载源")
        }
        guard let base = URL(string: root), base.scheme == "https", let host = base.host, !host.isEmpty,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw error("请输入 HTTPS 模型根目录，不要包含账号、密码、查询参数或文件名")
        }
        return base.appendingPathComponent(path)
    }

    // Bounded-memory copy into a sibling staging file; never replace a good file
    // until all bytes have been copied and the pinned SHA256 has matched.
    static func install(from source: URL, to target: URL, expectedHash: String,
                        cancelled: () -> Bool, report: (Int64) -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        guard manager.createFile(atPath: staging.path, contents: nil) else { throw error("无法创建模型临时文件，请检查剩余空间") }
        defer { try? manager.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        var digest = SHA256()
        var copied: Int64 = 0
        while let block = try input.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            if cancelled() { throw CancellationError() }
            digest.update(data: block)
            try output.write(contentsOf: block)
            copied += Int64(block.count); report(copied)
        }
        try output.synchronize()
        try output.close()
        if cancelled() { throw CancellationError() }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHash else { throw error("文件校验不匹配：可能选错主模型/语音解码器，或下载不完整。原有文件未替换。") }
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: staging)
        } else { try manager.moveItem(at: staging, to: target) }
    }
}
