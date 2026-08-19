import Foundation

@MainActor
final class ReaderViewModel: ObservableObject {
    nonisolated static let sampleParagraphs = [
        "阅读不是把文字从第一页搬到最后一页，而是在阅读过程中不断建立连接。",
        "本地优先意味着书籍、进度和笔记首先保存在用户自己的设备上。即使没有网络，阅读和朗读也应该完整可用。",
        "When a paragraph changes language, the speech queue can select a matching voice automatically without interrupting the reading flow.",
        "真正可靠的阅读器，需要在修改字号、切换设备或重新打开应用后，仍然准确回到上次的位置。",
        "高亮和批注不应该困在应用里。它们需要保留来源、可以搜索，也可以导出到用户选择的知识工具中。"
    ]

    let title: String
    @Published private(set) var paragraphs: [String]
    @Published var currentParagraph = 0
    @Published var playbackState: SpeechPlaybackState = .idle
    @Published var rate: Float = 0.5
    @Published var selectedVoiceID: String?
    private let engine: SystemSpeechEngine
    private let requestedStartIndex: Int
    var voices: [SpeechVoice] { engine.voices }
    private var segments: [SpeechSegment] { paragraphs.enumerated().map { SpeechSegment(id: $0.offset, text: $0.element, languageTag: detectedLanguage(for: $0.element)) } }

    init(title: String = "为什么阅读需要一个闭环", paragraphs: [String] = ReaderViewModel.sampleParagraphs, startIndex: Int = 0, engine: SystemSpeechEngine = SystemSpeechEngine()) {
        self.title = title
        self.paragraphs = paragraphs.isEmpty ? ["文件内容为空"] : paragraphs
        self.engine = engine
        self.requestedStartIndex = startIndex
        self.currentParagraph = min(max(0, startIndex), self.paragraphs.count - 1)
        engine.onSegmentStarted = { [weak self] index in Task { @MainActor in self?.currentParagraph = index } }
        engine.onQueueCompleted = { [weak self] in Task { @MainActor in self?.playbackState = .idle } }
    }

    func replaceParagraphs(_ values: [String]) {
        engine.stop()
        playbackState = .idle
        paragraphs = values.isEmpty ? ["文件内容为空"] : values
        currentParagraph = min(max(0, requestedStartIndex), paragraphs.count - 1)
    }

    func playOrPause() {
        switch playbackState {
        case .idle: engine.speak(segments: segments, from: currentParagraph, voiceID: selectedVoiceID, rate: rate); playbackState = .playing
        case .playing: engine.pause(); playbackState = .paused
        case .paused: engine.resume(); playbackState = .playing
        }
    }
    func previous() { move(to: max(0, currentParagraph - 1)) }
    func next() { move(to: min(paragraphs.count - 1, currentParagraph + 1)) }
    func move(to index: Int) { currentParagraph = index; restartIfActive() }
    func recordReadingPosition(_ index: Int) {
        currentParagraph = min(max(0, index), paragraphs.count - 1)
    }
    func chooseVoice(_ id: String?) { selectedVoiceID = id; restartIfActive() }
    func previewVoice(_ voice: SpeechVoice) {
        selectedVoiceID = voice.id
        let sample: String
        if voice.languageTag.hasPrefix("zh") { sample = "你好，我是归页。愿这段声音陪你读完每一本好书。" }
        else if voice.languageTag.hasPrefix("ja") { sample = "こんにちは。心地よい声で読書を楽しみましょう。" }
        else if voice.languageTag.hasPrefix("ko") { sample = "안녕하세요. 편안한 목소리로 책을 읽어 드릴게요." }
        else { sample = "Hello, this is Guiye Reader. Enjoy a natural and comfortable reading voice." }
        engine.speak(segments: [SpeechSegment(id: currentParagraph, text: sample, languageTag: voice.languageTag)], from: 0, voiceID: voice.id, rate: rate)
        playbackState = .playing
    }
    func updateRate(_ value: Float) { rate = value; restartIfActive() }
    private func restartIfActive() {
        guard playbackState != .idle else { return }
        engine.speak(segments: segments, from: currentParagraph, voiceID: selectedVoiceID, rate: rate); playbackState = .playing
    }
}
