import CryptoKit
import Foundation
import CoreFoundation

@MainActor
final class BookRepository: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var lastError: String?
    @Published private(set) var importProgress: Double?
    @Published private(set) var importStatus: String?
    @Published var importNotice: String?
    private let manager = FileManager.default
    private lazy var root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GuiyeReader", isDirectory: true)
    private var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
    private var libraryFile: URL { root.appendingPathComponent("library.json") }

    init() { load() }

    func importFiles(_ urls: [URL]) {
        guard importProgress == nil, !urls.isEmpty else { return }
        // Acquire security-scoped access before returning from the file importer callback.
        // Cloud and third-party file providers may revoke their temporary grant immediately after it.
        let scopedSources = urls.map { url in (url, url.startAccessingSecurityScopedResource()) }
        Task {
            defer {
                for (url, didStartAccess) in scopedSources where didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            lastError = nil
            var duplicates = 0
            var imported = 0
            var failures: [String] = []
            for (index, source) in scopedSources.enumerated() {
                let url = source.0
                importProgress = Double(index) / Double(scopedSources.count)
                importStatus = "正在导入 \(index + 1)/\(scopedSources.count) · \(url.lastPathComponent)"
                do {
                    if try await importFile(url) { duplicates += 1 }
                    else { imported += 1 }
                } catch {
                    lastError = error.localizedDescription
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            importProgress = nil
            if failures.isEmpty {
                importStatus = duplicates > 0 ? "已导入 \(imported) 本，跳过 \(duplicates) 本重复书籍" : "已成功导入 \(imported) 本书"
            } else {
                importStatus = "导入完成：成功 \(imported) 本，失败 \(failures.count) 本"
            }
            importNotice = failures.isEmpty ? importStatus : ([importStatus ?? "导入失败"] + failures).joined(separator: "\n")
        }
    }

    func paragraphs(for book: Book) -> [String] {
        guard book.format == .txt, let data = try? Data(contentsOf: book.localURL) else {
            return [book.format == .epub ? "EPUB 已安全导入本地书库。Readium 导航器正在接入。" : "PDF 已安全导入本地书库。PDF 导航器正在接入。"]
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(kCFStringEncodingGB_18030_2000)))
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: gb18030)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "无法识别文本编码"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func updateProgress(bookID: String, progress: Double) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].progress = min(max(progress, 0), 1)
        try? persist()
    }

    func backupData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(books)) ?? Data("[]".utf8)
    }

    private func importFile(_ source: URL) async throws -> Bool {
        guard let format = BookFormat(rawValue: source.pathExtension.lowercased()) else { throw ImportError.unsupported }
        try manager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        let temporary = booksDirectory.appendingPathComponent("import-\(UUID().uuidString).\(format.rawValue)")
        let result = try await Task.detached { () -> (String, Int64) in
            let values = try source.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > 2_147_483_648 { throw ImportError.tooLarge }
            try FileManager.default.copyItem(at: source, to: temporary)
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
            let id = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let size = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            if size > 2_147_483_648 { throw ImportError.tooLarge }
            return (id, size)
        }.value
        let (id, fileSize) = result
        guard !books.contains(where: { $0.id == id }) else { try? manager.removeItem(at: temporary); return true }
        let destination = booksDirectory.appendingPathComponent("\(id).\(format.rawValue)")
        try manager.moveItem(at: temporary, to: destination)
        books.insert(Book(id: id, title: source.deletingPathExtension().lastPathComponent, author: nil, format: format, localPath: destination.path, fileSize: fileSize, importedAt: Date(), progress: 0), at: 0)
        try persist(); lastError = nil
        return false
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile), let decoded = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = decoded.filter { manager.fileExists(atPath: $0.localPath) }.sorted { $0.importedAt > $1.importedAt }
    }
    private func persist() throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(books).write(to: libraryFile, options: .atomic)
    }
}

enum ImportError: LocalizedError {
    case unsupported, tooLarge
    var errorDescription: String? {
        switch self {
        case .unsupported: return "首版仅支持 EPUB、PDF 和 TXT"
        case .tooLarge: return "单个文件暂不能超过 2 GB"
        }
    }
}
