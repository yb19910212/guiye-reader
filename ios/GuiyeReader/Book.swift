import Foundation

enum BookFormat: String, Codable { case txt, epub, pdf }

struct Book: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var author: String?
    let format: BookFormat
    let localPath: String
    let fileSize: Int64
    let importedAt: Date
    var progress: Double
    var lastOpenedAt: Date? = nil
    var localURL: URL { URL(fileURLWithPath: localPath) }
}
