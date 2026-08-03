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
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map {
                SpeechVoice(
                    id: $0.identifier,
                    name: $0.name,
                    languageTag: $0.language,
                    quality: $0.quality == .enhanced ? "增强" : "标准"
                )
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
