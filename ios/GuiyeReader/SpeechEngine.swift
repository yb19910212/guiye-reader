import Foundation
import CryptoKit

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
    var qualityRank: Int { provider == "api" || provider == "qwen" ? 4 : (quality == "Premium" ? 3 : (quality == "增强" ? 2 : 1)) }
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
    private let maxCharacters: Int
    private var paragraph: Int
    private var offset: String.Index?
    init(segments: [SpeechSegment], from: Int, maxCharacters: Int = 80) {
        self.segments = segments
        self.maxCharacters = max(1, maxCharacters)
        paragraph = min(max(from, 0), segments.count)
    }
    mutating func next() -> SpeechSegment? {
        while paragraph < segments.count {
            let segment = segments[paragraph]
            let start = offset ?? segment.text.startIndex
            guard start < segment.text.endIndex else { paragraph += 1; offset = nil; continue }
            let limit = segment.text.index(start, offsetBy: maxCharacters, limitedBy: segment.text.endIndex) ?? segment.text.endIndex
            var end = limit
            if limit < segment.text.endIndex {
                let indexes = segment.text[start..<limit].indices
                let sentence = indexes.last { "。！？!?；;".contains(segment.text[$0]) }
                    ?? indexes.last { segment.text[$0] == "." && segment.text.index(after: $0) < segment.text.endIndex && segment.text[segment.text.index(after: $0)].isWhitespace }
                let clause = indexes.last { "，,：: ".contains(segment.text[$0]) }
                if let boundary = sentence ?? clause {
                    end = segment.text.index(after: boundary)
                    while end < limit && "”’」』\"".contains(segment.text[end]) { end = segment.text.index(after: end) }
                }
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

struct SpeechPreroll {
    let required: Int
    private(set) var waiting = true
    init(required: Int = 2) { self.required = max(1, required) }
    mutating func canPlay(ready: Int, ended: Bool) -> Bool {
        if ready == 0 { waiting = true; return false }
        if waiting && ready < required && !ended { return false }
        waiting = false
        return true
    }
}

struct SpeechProgress {
    var phase = "准备中"
    var completed = 0
    var total = 0
    var cached = 0
    var played = 0
    var characters = 0
    var audioSeconds: Double = 0
    var measuredAt = Date()
    var startedAt = Date()
    var requestStartedAt: Date?
    var preparingChapter = false
    var localTiming: String?
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum SpeechWAV {
    static func encode(samples: [Float], rate: Int = 24_000) throws -> Data {
        guard !samples.isEmpty, samples.count <= (8 * 1024 * 1024 - 44) / 2,
              (8_000...192_000).contains(rate), samples.allSatisfy({ $0.isFinite }) else {
            throw NSError(domain: "SpeechWAV", code: 2, userInfo: [NSLocalizedDescriptionKey: "模型返回无效音频"])
        }
        var result = Data()
        result.reserveCapacity(44 + samples.count * 2)
        func number(_ value: Int, _ bytes: Int) {
            for offset in 0..<bytes { result.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        result.append(contentsOf: "RIFF".utf8); number(36 + samples.count * 2, 4)
        result.append(contentsOf: "WAVEfmt ".utf8); number(16, 4); number(1, 2); number(1, 2)
        number(rate, 4); number(rate * 2, 4); number(2, 2); number(16, 2)
        result.append(contentsOf: "data".utf8); number(samples.count * 2, 4)
        for sample in samples { number(Int((min(1, max(-1, sample)) * 32767).rounded()), 2) }
        return result
    }
    static func duration(_ data: Data) throws -> Double {
        func number(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 44, data.count <= 8 * 1024 * 1024,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              String(data: data[12..<16], encoding: .ascii) == "fmt ",
              number(16, 4) == 16, number(20, 2) == 1, number(22, 2) == 1,
              number(34, 2) == 16,
              String(data: data[36..<40], encoding: .ascii) == "data",
              number(4, 4) + 8 == data.count, number(40, 4) + 44 == data.count,
              number(40, 4) > 0, number(40, 4) % 2 == 0,
              number(24, 4) > 0, number(28, 4) == number(24, 4) * 2 else {
            throw NSError(domain: "SpeechWAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "音频不完整或格式不支持，请重试"])
        }
        return Double(number(40, 4)) / Double(number(28, 4))
    }
}
actor SpeechDiskCache {
    static let shared = SpeechDiskCache()
    private let directory: URL
    private let capacity: Int
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("speech-v2", isDirectory: true), capacity: Int = 200 * 1024 * 1024) {
        self.directory = directory; self.capacity = capacity
    }
    func file(identity: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".wav")
    }
    func read(_ file: URL) -> Double? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let duration = try? SpeechWAV.duration(data) else { try? FileManager.default.removeItem(at: file); return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return duration
    }
    func save(_ data: Data, to file: URL, protecting: Set<URL> = []) throws -> Double {
        let duration = try SpeechWAV.duration(data)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "wav" }
        let entries = files.map { url -> (URL, Int, Date) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        var used = entries.reduce(0) { $0 + ($1.0 == file ? 0 : $1.1) }
        let victims = entries.filter { $0.0 != file && !protecting.contains($0.0) }.sorted { $0.2 < $1.2 }
        guard used + data.count - victims.reduce(0, { $0 + $1.1 }) <= capacity else {
            throw NSError(domain: "SpeechCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前章节待播音频已超过缓存预算，请改用边生成边播放；无需清空全部缓存"])
        }
        for victim in victims where used + data.count > capacity {
            try FileManager.default.removeItem(at: victim.0); used -= victim.1
        }
        try data.write(to: file, options: .atomic)
        return duration
    }
    func clear() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
}
