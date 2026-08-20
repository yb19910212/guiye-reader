import Foundation

struct ReadingNote: Identifiable, Codable, Hashable {
    let id: UUID
    let bookID: String
    let bookTitle: String
    var text: String
    let locator: String?
    let createdAt: Date
    var quote: String? = nil
    var color: String? = nil
    var tags: [String]? = nil
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [ReadingNote] = []
    private let key = "guiye.readingNotes"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        notes = (try? JSONDecoder().decode([ReadingNote].self, from: data)) ?? []
    }

    func add(book: Book, text: String, locator: String? = nil, tags: [String] = []) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: cleaned, locator: locator, createdAt: Date(), tags: tags), at: 0)
        persist()
    }

    func addHighlight(book: Book, quote: String, locator: String, color: String = "yellow") {
        let cleaned = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: cleaned, locator: locator, createdAt: Date(), quote: cleaned, color: color), at: 0)
        persist()
    }

    func addAnnotation(book: Book, text: String, quote: String, locator: String, tags: [String] = []) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: cleaned, locator: locator, createdAt: Date(), quote: quote, color: "annotation", tags: tags), at: 0)
        persist()
    }

    func setHighlight(book: Book, quote: String, locator: String, color: String?) {
        notes.removeAll { $0.bookID == book.id && $0.locator == locator && $0.color != "annotation" && $0.quote != nil }
        if let color {
            notes.insert(ReadingNote(id: UUID(), bookID: book.id, bookTitle: book.title, text: quote, locator: locator, createdAt: Date(), quote: quote, color: color), at: 0)
        }
        persist()
    }

    func highlight(bookID: String, locator: String) -> ReadingNote? {
        notes.first { $0.bookID == bookID && $0.locator == locator && $0.color != "annotation" && $0.quote != nil }
    }

    func update(id: UUID, text: String, tags: [String]) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        notes[index].text = cleaned
        notes[index].tags = tags
        persist()
    }

    func remove(ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
        persist()
    }

    func merge(_ imported: [ReadingNote]) {
        let existing = Set(notes.map(\.id))
        notes = (notes + imported.filter { !existing.contains($0.id) }).sorted { $0.createdAt > $1.createdAt }
        persist()
    }

    var markdown: String {
        notes.map { note in
            let quote = note.quote.map { "> \($0)\n\n" } ?? ""
            let locator = note.locator.map { " · \($0)" } ?? ""
            let tags = (note.tags ?? []).map { "#\($0)" }.joined(separator: " ")
            return "## \(note.bookTitle)\n\n\(quote)\(note.text)\n\n\(tags.isEmpty ? "" : "\(tags)\n\n")_\(note.createdAt.formatted())\(locator)_"
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

    func merge(_ imported: [ReadingBookmark]) {
        let existing = Set(bookmarks.map(\.id))
        bookmarks = bookmarks + imported.filter { !existing.contains($0.id) }
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: key)
    }
}

@MainActor
final class ReadingStatsStore: ObservableObject {
    @Published private(set) var dailySeconds: [String: TimeInterval] = [:]
    @Published var goalMinutes: Int { didSet { UserDefaults.standard.set(goalMinutes, forKey: goalKey) } }
    private let recordsKey = "guiye.readingStats.daily"
    private let goalKey = "guiye.readingStats.goalMinutes"
    private var sessionStartedAt: Date?
    private let calendar = Calendar.current

    init() {
        dailySeconds = (UserDefaults.standard.dictionary(forKey: recordsKey) as? [String: Double]) ?? [:]
        let savedGoal = UserDefaults.standard.integer(forKey: goalKey)
        goalMinutes = savedGoal > 0 ? savedGoal : 30
    }

    func startSession() {
        guard sessionStartedAt == nil else { return }
        sessionStartedAt = Date()
    }

    func stopSession() {
        guard let started = sessionStartedAt else { return }
        sessionStartedAt = nil
        let elapsed = max(0, Date().timeIntervalSince(started))
        guard elapsed >= 1 else { return }
        dailySeconds[dateKey(Date()), default: 0] += elapsed
        UserDefaults.standard.set(dailySeconds, forKey: recordsKey)
    }

    var todaySeconds: TimeInterval { dailySeconds[dateKey(Date()), default: 0] }
    var todayProgress: Double { min(todaySeconds / Double(max(goalMinutes, 1) * 60), 1) }
    var streak: Int {
        var date = Date()
        if dailySeconds[dateKey(date), default: 0] < 1 { date = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
        var count = 0
        while dailySeconds[dateKey(date), default: 0] >= 1 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }
    var lastSevenDays: [(date: Date, seconds: TimeInterval)] {
        (0..<7).reversed().compactMap { offset in calendar.date(byAdding: .day, value: -offset, to: Date()).map { ($0, dailySeconds[dateKey($0), default: 0]) } }
    }

    func merge(daily: [String: TimeInterval], goal: Int) {
        daily.forEach { dailySeconds[$0.key] = max(dailySeconds[$0.key, default: 0], $0.value) }
        if goal > 0 { goalMinutes = goal }
        UserDefaults.standard.set(dailySeconds, forKey: recordsKey)
    }

    private func dateKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct ReadingPlan: Identifiable, Codable, Hashable {
    let bookID: String
    let bookTitle: String
    let createdAt: Date
    let deadline: Date
    var id: String { bookID }
}

@MainActor
final class ReadingPlanStore: ObservableObject {
    @Published private(set) var plans: [ReadingPlan] = []
    private let key = "guiye.readingPlans"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        plans = (try? JSONDecoder().decode([ReadingPlan].self, from: data)) ?? []
    }

    func set(book: Book, days: Int) {
        let deadline = Calendar.current.date(byAdding: .day, value: max(days, 1), to: Date()) ?? Date()
        plans.removeAll { $0.bookID == book.id }
        plans.append(ReadingPlan(bookID: book.id, bookTitle: book.title, createdAt: Date(), deadline: deadline))
        persist()
    }
    func remove(bookID: String) { plans.removeAll { $0.bookID == bookID }; persist() }
    func merge(_ imported: [ReadingPlan]) {
        imported.forEach { plan in
            if let index = plans.firstIndex(where: { $0.bookID == plan.bookID }) {
                if plan.deadline > plans[index].deadline { plans[index] = plan }
            } else { plans.append(plan) }
        }
        persist()
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(plans), forKey: key) }
}

