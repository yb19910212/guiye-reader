import Foundation

struct ReadingNote: Identifiable, Codable, Hashable {
    let id: UUID
    let bookID: String
    let bookTitle: String
    let text: String
    let locator: String?
    let createdAt: Date
    var quote: String? = nil
    var color: String? = nil
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [ReadingNote] = []
    private let key = "guiye.readingNotes"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        notes = (try? JSONDecoder().decode([ReadingNote].self, from: data)) ?? []
    }

    func add(book: Book, text: String, locator: String? = nil) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: cleaned, locator: locator, createdAt: Date()), at: 0)
        persist()
    }

    func addHighlight(book: Book, quote: String, locator: String, color: String = "yellow") {
        let cleaned = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: cleaned, locator: locator, createdAt: Date(), quote: cleaned, color: color), at: 0)
        persist()
    }

    func addAnnotation(book: Book, text: String, quote: String, locator: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: cleaned, locator: locator, createdAt: Date(), quote: quote, color: "annotation"), at: 0)
        persist()
    }

    func remove(ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
        persist()
    }

    var markdown: String {
        notes.map { note in
            let quote = note.quote.map { "> \($0)\n\n" } ?? ""
            let locator = note.locator.map { " · \($0)" } ?? ""
            return "## \(note.bookTitle)\n\n\(quote)\(note.text)\n\n_\(note.createdAt.formatted())\(locator)_"
        }.joined(separator: "\n\n---\n\n")
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(notes), forKey: key)
    }
}

struct ReadingBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    let bookID: String
    let bookTitle: String
    let paragraphIndex: Int
    let excerpt: String
    let createdAt: Date
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [ReadingBookmark] = []
    private let key = "guiye.readingBookmarks"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        bookmarks = (try? JSONDecoder().decode([ReadingBookmark].self, from: data)) ?? []
    }

    func forBook(_ bookID: String) -> [ReadingBookmark] {
        bookmarks.filter { $0.bookID == bookID }.sorted { $0.paragraphIndex < $1.paragraphIndex }
    }

    func isBookmarked(bookID: String, paragraphIndex: Int) -> Bool {
        bookmarks.contains { $0.bookID == bookID && $0.paragraphIndex == paragraphIndex }
    }

    func toggle(book: Book, paragraphIndex: Int, excerpt: String) {
        if let index = bookmarks.firstIndex(where: { $0.bookID == book.id && $0.paragraphIndex == paragraphIndex }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(ReadingBookmark(id: UUID(), bookID: book.id, bookTitle: book.title, paragraphIndex: paragraphIndex, excerpt: excerpt, createdAt: Date()), at: 0)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: key)
    }
}

