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

    var isOpenSource: Bool { provider == "kokoro" }
    var qualityRank: Int { provider == "kokoro" ? 4 : (quality == "Premium" ? 3 : (quality == "增强" ? 2 : 1)) }
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
