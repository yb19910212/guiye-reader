import Foundation

struct ReadingNote: Identifiable, Codable, Hashable {
    let id: UUID
    let bookID: String
    let bookTitle: String
    let text: String
    let locator: String?
    let createdAt: Date
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

    func remove(ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
        persist()
    }

    var markdown: String {
        notes.map { "## \($0.bookTitle)\n\n\($0.text)\n\n> \($0.createdAt.formatted())" }.joined(separator: "\n\n---\n\n")
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(notes), forKey: key)
    }
}
