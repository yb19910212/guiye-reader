import CryptoKit
import Foundation

@MainActor
final class BookRepository: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var lastError: String?
    private let manager = FileManager.default
    private lazy var root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GuiyeReader", isDirectory: true)
    private var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
    private var libraryFile: URL { root.appendingPathComponent("library.json") }

    init() { load() }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            do { try importFile(url) } catch { lastError = error.localizedDescription }
        }
    }

    func paragraphs(for book: Book) -> [String] {
        guard book.format == .txt, let data = try? Data(contentsOf: book.localURL) else {
            return [book.format == .epub ? "EPUB 已安全导入本地书库。Readium 导航器正在接入。" : "PDF 已安全导入本地书库。PDF 导航器正在接入。"]
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) ?? "无法识别文本编码"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func importFile(_ source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let format = BookFormat(rawValue: source.pathExtension.lowercased()) else { throw ImportError.unsupported }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !books.contains(where: { $0.id == id }) else { return }
        try manager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        let destination = booksDirectory.appendingPathComponent("\(id).\(format.rawValue)")
        try data.write(to: destination, options: .atomic)
        books.insert(Book(id: id, title: source.deletingPathExtension().lastPathComponent, author: nil, format: format, localPath: destination.path, fileSize: Int64(data.count), importedAt: Date(), progress: 0), at: 0)
        try persist(); lastError = nil
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
    case unsupported
    var errorDescription: String? { "首版仅支持 EPUB、PDF 和 TXT" }
}
