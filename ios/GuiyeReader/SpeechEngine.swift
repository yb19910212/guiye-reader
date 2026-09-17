import Foundation

struct SpeechVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let languageTag: String
    let quality: String
    let isNetworkRequired: Bool
    let provider: String

    init(id: String, name: String, languageTag: String, quality: String, isNetworkRequired: Bool = false, provider: String = "system") {
        self.id = id
        self.name = name
        self.languageTag = languageTag
        self.quality = quality
        self.isNetworkRequired = isNetworkRequired
        self.provider = provider
    }

    var isOpenSource: Bool { provider == "kokoro" || provider == "qwen" }
    var qualityRank: Int { provider == "api" ? 4 : (quality == "Premium" ? 3 : (quality == "增强" ? 2 : 1)) }
    var languageName: String {
        let locale = Locale(identifier: "zh-Hans")
        return locale.localizedString(forIdentifier: languageTag) ?? languageTag
    }
}

struct SpeechSegment: Identifiable, Hashable {
    let id: Int
    let text: String
    let languageTag: String
}

enum SpeechPlaybackState {
    case idle, playing, paused
}

protocol SpeechEngine: AnyObject {
    var voices: [SpeechVoice] { get }
    var onSegmentStarted: ((Int) -> Void)? { get set }
    var onQueueCompleted: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func speak(segments: [SpeechSegment], from index: Int, voiceID: String?, rate: Float)
    func pause()
    func resume()
    func stop()
}

func detectedLanguage(for text: String) -> String {
    let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
    let latin = text.unicodeScalars.filter { $0.properties.isAlphabetic && $0.value < 0x0250 }.count
    if cjk > latin / 3 { return "zh-CN" }
    if latin > 0 { return "en-US" }
    return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
}

// Only the main thread owns a cursor/window. Workers share cancellation only.
final class SpeechCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct SpeechPrefetchWindow {
    let capacity: Int
    private(set) var requested = 0
    private(set) var played = 0
    init(capacity: Int = 3) { self.capacity = max(1, capacity) }
    var canRequest: Bool { requested - played < capacity }
    mutating func reserve() -> Int? {
        guard canRequest else { return nil }
        defer { requested += 1 }
        return requested
    }
    mutating func advance() { if played < requested { played += 1 } }
}

struct SpeechChunkCursor {
    private let segments: [SpeechSegment]
    private var paragraph: Int
    private var offset: String.Index?
    init(segments: [SpeechSegment], from: Int) {
        self.segments = segments
        paragraph = min(max(from, 0), segments.count)
    }
    mutating func next() -> SpeechSegment? {
        while paragraph < segments.count {
            let segment = segments[paragraph]
            let start = offset ?? segment.text.startIndex
            guard start < segment.text.endIndex else { paragraph += 1; offset = nil; continue }
            let limit = segment.text.index(start, offsetBy: 48, limitedBy: segment.text.endIndex) ?? segment.text.endIndex
            var end = limit
            if limit < segment.text.endIndex {
                let boundary = segment.text[start..<limit].indices.last { index in
                    "。！？；，.!?;, \n".contains(segment.text[index]) && segment.text.distance(from: start, to: index) >= 16
                }
                if let boundary { end = segment.text.index(after: boundary) }
            }
            offset = end
            let text = String(segment.text[start..<end])
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SpeechSegment(id: segment.id, text: text, languageTag: segment.languageTag)
            }
        }
        return nil
    }
}
