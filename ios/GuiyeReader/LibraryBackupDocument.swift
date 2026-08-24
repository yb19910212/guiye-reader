import SwiftUI
import UniformTypeIdentifiers

struct GuiyeBackup: Codable {
    let version: Int
    let exportedAt: Date
    let books: [Book]
    let notes: [ReadingNote]
    let bookmarks: [ReadingBookmark]
    let textPositions: [String: Int]
    let readingStats: [String: Double]?
    let goalMinutes: Int?
    let readingPlans: [ReadingPlan]?
    let reminderEnabled: Bool?
    let reminderHour: Int?
    let reminderMinute: Int?
}

struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data = Data("{}".utf8)) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
