import AVFoundation
import Foundation

final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [SpeechSegment] = []
    private var currentIndex = 0
    private var voiceID: String?
    private var rate: Float = 0.5
    private var intentionallyPaused = false

    var onSegmentStarted: ((Int) -> Void)?
    var onQueueCompleted: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var voices: [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map {
                let quality: String
                switch $0.quality {
                case .premium: quality = "Premium"
                case .enhanced: quality = "增强"
                default: quality = "标准"
                }
                SpeechVoice(
                    id: $0.identifier,
                    name: $0.name,
                    languageTag: $0.language,
                    quality: quality
                )
            }
            .sorted {
                if $0.qualityRank != $1.qualityRank { return $0.qualityRank > $1.qualityRank }
                let leftPreferred = $0.languageTag.hasPrefix("zh") || $0.languageTag.hasPrefix("en")
                let rightPreferred = $1.languageTag.hasPrefix("zh") || $1.languageTag.hasPrefix("en")
                if leftPreferred != rightPreferred { return leftPreferred }
                return ($0.languageTag, $0.name) < ($1.languageTag, $1.name)
            }
    }

    func speak(segments: [SpeechSegment], from index: Int, voiceID: String?, rate: Float) {
        stop()
        guard !segments.isEmpty else { return }
        queue = segments
        currentIndex = min(max(0, index), segments.count - 1)
        self.voiceID = voiceID
        self.rate = rate
        intentionallyPaused = false
        speakCurrent()
    }

    private func speakCurrent() {
        guard queue.indices.contains(currentIndex) else {
            onQueueCompleted?()
            return
        }
        let segment = queue[currentIndex]
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.12
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: segment.languageTag)
        synthesizer.speak(utterance)
    }

    func pause() {
        intentionallyPaused = true
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        intentionallyPaused = false
        synthesizer.continueSpeaking()
    }

    func stop() {
        intentionallyPaused = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSegmentStarted?(queue[currentIndex].id)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !intentionallyPaused else { return }
        currentIndex += 1
        if currentIndex < queue.count { speakCurrent() } else { onQueueCompleted?() }
    }
}
