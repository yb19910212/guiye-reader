import Foundation
import CryptoKit

@main struct OfflineModelFilesSmoke {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("installed/model.safetensors")
        let data = Data(repeating: 37, count: 5 * 1024 * 1024)
        try data.write(to: source)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try OfflineModelFiles.install(from: source, to: target, expectedHash: hash, cancelled: { false }, report: { _ in })
        check(try Data(contentsOf: target) == data)
        do {
            try OfflineModelFiles.install(from: source, to: target, expectedHash: "wrong", cancelled: { false }, report: { _ in })
            fatalError("Corrupt import accepted")
        } catch {}
        check(try Data(contentsOf: target) == data)
        do {
            try OfflineModelFiles.install(from: source, to: target, expectedHash: hash, cancelled: { true }, report: { _ in })
            fatalError("Cancelled import accepted")
        } catch is CancellationError {}
        check(try Data(contentsOf: target) == data)
        try OfflineModelFiles.install(from: source, to: target, expectedHash: hash, cancelled: { false }, report: { _ in })
        check(try Data(contentsOf: target) == data)
        let files = try FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        assert(files.count == 1, "Staging files leaked")
        for path in OfflineModelFiles.paths {
            check(try OfflineModelFiles.sourceURL(path: path, source: "official", custom: "").host == "huggingface.co")
            check(try OfflineModelFiles.sourceURL(path: path, source: "mirror", custom: "").host == "hf-mirror.com")
            check(try OfflineModelFiles.sourceURL(path: path, source: "custom", custom: "https://example.com/models/").path == "/models/" + path)
        }
        for bad in ["http://example.com", "https://user:secret@example.com", "https://example.com/?key=secret", "not a URL"] {
            do {
                _ = try OfflineModelFiles.sourceURL(path: "model.safetensors", source: "custom", custom: bad)
                fatalError("Unsafe URL accepted")
            } catch {}
        }
        print("Model import/source tests passed: valid import, mismatch preservation, cancellation, atomic replacement, cleanup, source validation")
    }
}
