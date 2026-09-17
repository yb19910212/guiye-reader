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
    @Published private(set) var chapters: [TXTChapter]
    @Published var currentParagraph = 0
    @Published var playbackState: SpeechPlaybackState = .idle
    @Published var rate: Float = 0.5
    @Published var selectedVoiceID: String?
    @Published private(set) var speechMessage: String?
    @Published private(set) var speechProgress: SpeechProgress?
    var playbackTime: String { engine.playbackTime }
    private let engine: SystemSpeechEngine
    private let requestedStartIndex: Int
    private var chapterTask: Task<Void, Never>?
    private var speechRestartTask: Task<Void, Never>?
    var voices: [SpeechVoice] { engine.voices }
    private var cachedSpeechSegments: [SpeechSegment]?
    private var segments: [SpeechSegment] {
        if let cachedSpeechSegments { return cachedSpeechSegments }
        let values = paragraphs.enumerated().map { SpeechSegment(id: $0.offset, text: $0.element, languageTag: "zh-CN") }
        cachedSpeechSegments = values
        return values
    }

    init(title: String = "为什么阅读需要一个闭环", paragraphs: [String] = ReaderViewModel.sampleParagraphs, startIndex: Int = 0, engine: SystemSpeechEngine = SystemSpeechEngine()) {
        let normalizedParagraphs = paragraphs.isEmpty ? ["文件内容为空"] : paragraphs
        self.title = title
        self.paragraphs = normalizedParagraphs
        self.chapters = []
        self.engine = engine
        self.requestedStartIndex = startIndex
        self.currentParagraph = min(max(0, startIndex), self.paragraphs.count - 1)
        engine.onSegmentStarted = { [weak self] index in Task { @MainActor in self?.currentParagraph = index } }
        engine.onQueueCompleted = { [weak self] in Task { @MainActor in self?.playbackState = .idle; self?.speechMessage = "本次朗读已完成" } }
        engine.onProgress = { [weak self] value in Task { @MainActor in self?.speechProgress = value } }
        engine.onStatus = { [weak self] message in Task { @MainActor in self?.speechMessage = message } }
        engine.onError = { [weak self] message in Task { @MainActor in self?.speechMessage = message; self?.playbackState = .idle } }
        loadChapters(normalizedParagraphs)
    }

    func replaceParagraphs(_ values: [String]) {
        speechRestartTask?.cancel(); speechRestartTask = nil
        engine.stop()
        playbackState = .idle
        paragraphs = values.isEmpty ? ["文件内容为空"] : values
        cachedSpeechSegments = nil
        loadChapters(paragraphs)
        currentParagraph = min(max(0, requestedStartIndex), paragraphs.count - 1)
    }

    private func loadChapters(_ values: [String]) {
        chapterTask?.cancel()
        chapters = []
        chapterTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { TXTParser.chapters(in: values) }.value
            guard !Task.isCancelled else { return }
            self?.chapters = result
        }
    }

    func search(_ query: String, limit: Int = 100) -> [TXTSearchResult] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        var results: [TXTSearchResult] = []
        for (index, paragraph) in paragraphs.enumerated() where paragraph.localizedCaseInsensitiveContains(value) {
            results.append(TXTSearchResult(index: index, text: paragraph))
            if results.count == limit { break }
        }
        return results
    }

    func playOrPause() {
        if speechRestartTask != nil {
            speechRestartTask?.cancel(); speechRestartTask = nil
            engine.stop(); playbackState = .idle
            return
        }
        switch playbackState {
        case .idle: playbackState = .playing; engine.speak(segments: segments, from: currentParagraph, voiceID: selectedVoiceID, rate: rate)
        case .playing: engine.pause(); playbackState = .paused
        case .paused: engine.resume(); playbackState = .playing
        }
    }
    func cacheChapter() {
        guard selectedVoiceID?.hasPrefix("api:") == true || selectedVoiceID?.hasPrefix("qwen:") == true else { return }
        stopSpeech()
        let start = chapters.last(where: { $0.index <= currentParagraph })?.index ?? 0
        let end = chapters.first(where: { $0.index > currentParagraph })?.index ?? paragraphs.count
        playbackState = .playing
        engine.prepareChapter(segments: (start..<end).map { SpeechSegment(id: $0, text: paragraphs[$0], languageTag: "zh-CN") }, voiceID: selectedVoiceID, rate: rate)
    }
    func clearSpeechCache() { stopSpeech(); engine.clearCache() }
    func cancelSpeech() { stopSpeech(); speechMessage = "已取消，已完成缓存保留；可重新缓存本章继续" }
    func stopSpeech() {
        speechRestartTask?.cancel(); speechRestartTask = nil
        engine.stop(); playbackState = .idle
    }
    func moveChapter(_ direction: Int) {
        let current = chapters.lastIndex(where: { $0.index <= currentParagraph }) ?? 0
        let next = min(max(0, current + direction), chapters.count - 1)
        guard chapters.indices.contains(next) else { return }
        move(to: chapters[next].index)
    }
    func previous() { move(to: max(0, currentParagraph - 1)) }
    func next() { move(to: min(paragraphs.count - 1, currentParagraph + 1)) }
    func move(to index: Int) { currentParagraph = index; restartIfActive() }
    func recordReadingPosition(_ index: Int) {
        currentParagraph = min(max(0, index), paragraphs.count - 1)
    }
    func chooseVoice(_ id: String?) {
        selectedVoiceID = id
        speechMessage = nil
        restartIfActive(delay: 200_000_000)
    }
    func previewVoice(_ voice: SpeechVoice) {
        speechRestartTask?.cancel(); speechRestartTask = nil
        selectedVoiceID = voice.id
        let sample: String
        if voice.languageTag.hasPrefix("zh") { sample = "你好，我是归页。愿这段声音陪你读完每一本好书。" }
        else if voice.languageTag.hasPrefix("ja") { sample = "こんにちは。心地よい声で読書を楽しみましょう。" }
        else if voice.languageTag.hasPrefix("ko") { sample = "안녕하세요. 편안한 목소리로 책을 읽어 드릴게요." }
        else { sample = "Hello, this is Guiye Reader. Enjoy a natural and comfortable reading voice." }
        playbackState = .playing
        engine.speak(segments: [SpeechSegment(id: currentParagraph, text: sample, languageTag: voice.languageTag)], from: 0, voiceID: voice.id, rate: rate)
    }
    func updateRate(_ value: Float) { rate = value; if selectedVoiceID?.hasPrefix("api:") == true || selectedVoiceID?.hasPrefix("qwen:") == true { engine.setRate(value) } else { restartIfActive(delay: 350_000_000) } }
    private func restartIfActive(delay: UInt64 = 0) {
        speechRestartTask?.cancel(); speechRestartTask = nil
        guard playbackState != .idle else { return }
        let wasPlaying = playbackState == .playing
        engine.stop()
        guard wasPlaying else { playbackState = .idle; return }
        speechRestartTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self else { return }
            self.speechRestartTask = nil
            self.engine.speak(segments: self.segments, from: self.currentParagraph, voiceID: self.selectedVoiceID, rate: self.rate)
        }
    }
    deinit { speechRestartTask?.cancel(); chapterTask?.cancel() }
}
