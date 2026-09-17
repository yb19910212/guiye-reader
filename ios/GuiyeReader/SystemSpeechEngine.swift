import AVFoundation
import Foundation
import SherpaOnnx
import UIKit
import MLX
import Qwen3TTS

final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    private static let qwenVoices = [
        SpeechVoice(id: "qwen:gentle", name: "温柔自然 · 1号", languageTag: "zh-CN", quality: "实验版", provider: "qwen"),
        SpeechVoice(id: "qwen:coaxing", name: "温柔微嗲 · 4号", languageTag: "zh-CN", quality: "实验版", provider: "qwen")
    ]
    private static let kokoroVoices = [
        SpeechVoice(id: "kokoro:3", name: "甜橙 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:8", name: "蜜桃 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:20", name: "月光 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:40", name: "清泉 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:0", name: "Maple · 英语女声", languageTag: "en-US", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:1", name: "Sol · 英语女声", languageTag: "en-US", quality: "开源神经", provider: "kokoro")
    ]

    private let synthesizer = AVSpeechSynthesizer()
    // All instances share one serial native engine, avoiding simultaneous model loads.
    private static let synthesisQueue = DispatchQueue(label: "com.guiye.reader.kokoro", qos: .userInitiated)
    private static var offlineTts: SherpaOnnxOfflineTtsWrapper?
    private var queue: [SpeechSegment] = []
    private var currentIndex = 0
    private var voiceID: String?
    private var rate: Float = 0.5
    private var intentionallyPaused = false
    private var player: AVAudioPlayer?
    private var session = SpeechCancellation()
    private var activeUtterance: AVSpeechUtterance?
    private var cursor: SpeechChunkCursor?
    private var window = SpeechPrefetchWindow()
    private var ready: [Int: (SpeechSegment, Data)] = [:]
    private var sourceEnded = false
    private var memoryObserver: NSObjectProtocol?
    private var inactiveObserver: NSObjectProtocol?
    private var isNeuralVoice: Bool { voiceID?.hasPrefix("kokoro:") == true || voiceID?.hasPrefix("qwen:") == true }

    var onSegmentStarted: ((Int) -> Void)?
    var onQueueCompleted: (() -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.fail("设备内存紧张，已停止语音。请切换系统语音或 Kokoro 后重试。")
            Self.synthesisQueue.async { Self.offlineTts = nil; QwenOfflineRuntime.release() }
        }
        inactiveObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.voiceID?.hasPrefix("qwen:") == true else { return }
            self.fail("Qwen 实验版暂限前台朗读，离开前台已停止。后台听书请选 Kokoro 或系统语音。")
            Self.synthesisQueue.async { QwenOfflineRuntime.release() }
        }
    }

    var voices: [SpeechVoice] {
        Self.qwenVoices + Self.kokoroVoices + AVSpeechSynthesisVoice.speechVoices()
            .map {
                let quality: String
                switch $0.quality {
                case .premium: quality = "Premium"
                case .enhanced: quality = "增强"
                default: quality = "标准"
                }
                return SpeechVoice(id: $0.identifier, name: $0.name, languageTag: $0.language, quality: quality)
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
        if voiceID?.hasPrefix("qwen:") == true && UIApplication.shared.applicationState != .active {
            fail("Qwen 实验版暂限前台使用，请返回应用后重试。")
            return
        }
        if isNeuralVoice {
            cursor = SpeechChunkCursor(segments: segments, from: currentIndex)
        } else {
            let token = session
            Self.synthesisQueue.async {
                guard !token.isCancelled else { return }
                Self.offlineTts = nil; QwenOfflineRuntime.release()
            }
        }
        speakCurrent()
    }

    private func speakCurrent() {
        guard queue.indices.contains(currentIndex) else { onQueueCompleted?(); return }
        let segment = queue[currentIndex]
        if isNeuralVoice {
            pumpOffline()
            return
        }
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.12
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: segment.languageTag)
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func pumpOffline() {
        guard !session.isCancelled, !intentionallyPaused else { return }
        while window.canRequest && !sourceEnded {
            guard let segment = cursor?.next() else { sourceEnded = true; break }
            guard let part = window.reserve() else { break }
            synthesizeOffline(segment, part: part)
        }
        startReadyAudio()
    }

    private func synthesizeOffline(_ segment: SpeechSegment, part: Int) {
        let token = session
        let qwenReference = voiceID?.hasPrefix("qwen:") == true ? voiceID?.replacingOccurrences(of: "qwen:", with: "") : nil
        let sid = Int(voiceID?.replacingOccurrences(of: "kokoro:", with: "") ?? "3") ?? 3
        let speed = min(max(0.6 + (rate - 0.35) / 0.30, 0.6), 1.6)
        Self.synthesisQueue.async { [weak self] in
            guard !token.isCancelled else { return }
            do {
                if let qwenReference {
                    Self.offlineTts = nil
                    let samples = try QwenOfflineRuntime.generate(text: segment.text, reference: qwenReference, token: token)
                    guard !token.isCancelled else { return }
                    let data = Self.wavData(samples: samples, sampleRate: 24_000)
                    DispatchQueue.main.async {
                        guard let self, self.session === token, !token.isCancelled else { return }
                        self.ready[part] = (segment, data)
                        self.startReadyAudio()
                    }
                    return
                }
                QwenOfflineRuntime.release()
                let engine: SherpaOnnxOfflineTtsWrapper
                if let existing = Self.offlineTts {
                    engine = existing
                } else {
                    engine = try Self.createOfflineTts()
                    Self.offlineTts = engine
                }
                guard !token.isCancelled else { return }
                guard sid >= 0, sid < Int(engine.numSpeakers) else { throw OfflineSpeechError.invalidVoice }
                let audio = engine.generateWithCallbackWithArg(text: segment.text, callback: { _, _, raw in
                    guard let raw else { return 0 }
                    return Unmanaged<SpeechCancellation>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 0 : 1
                }, arg: Unmanaged.passUnretained(token).toOpaque(), sid: sid, speed: speed)
                guard !token.isCancelled else { return }
                let samples = audio.samples
                guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw OfflineSpeechError.emptyAudio }
                let data = Self.wavData(samples: samples, sampleRate: Int(audio.sampleRate))
                DispatchQueue.main.async {
                    guard let self, self.session === token, !token.isCancelled else { return }
                    self.ready[part] = (segment, data)
                    self.startReadyAudio()
                }
            } catch {
                DispatchQueue.main.async {
                    if let self, self.session === token, !token.isCancelled {
                        self.fail("离线语音初始化失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func startReadyAudio() {
        guard !session.isCancelled, !intentionallyPaused, player == nil else { return }
        guard let (segment, data) = ready.removeValue(forKey: window.played) else {
            if sourceEnded && window.played == window.requested { stop(); onQueueCompleted?() }
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(data: data)
            if voiceID?.hasPrefix("qwen:") == true {
                next.enableRate = true
                next.rate = min(max(0.6 + (rate - 0.35) / 0.30, 0.6), 1.6)
            }
            player = next
            next.delegate = self
            next.prepareToPlay()
            guard next.play() else { throw OfflineSpeechError.emptyAudio }
            onSegmentStarted?(segment.id)
        } catch { fail("离线语音播放失败：\(error.localizedDescription)") }
    }

    private static func createOfflineTts() throws -> SherpaOnnxOfflineTtsWrapper {
        let base = Bundle.main.bundleURL.appendingPathComponent("KokoroModel", isDirectory: true)
        let required = ["model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-zh.txt", "date-zh.fst", "phone-zh.fst", "number-zh.fst"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }),
              FileManager.default.fileExists(atPath: base.appendingPathComponent("espeak-ng-data/phontab").path) else {
            throw OfflineSpeechError.modelMissing
        }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: base.appendingPathComponent("model.int8.onnx").path,
            voices: base.appendingPathComponent("voices.bin").path,
            tokens: base.appendingPathComponent("tokens.txt").path,
            dataDir: base.appendingPathComponent("espeak-ng-data").path,
            lexicon: "\(base.appendingPathComponent("lexicon-us-en.txt").path),\(base.appendingPathComponent("lexicon-zh.txt").path)"
        )
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 4)
        let rules = ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map { base.appendingPathComponent($0).path }.joined(separator: ",")
        var config = sherpaOnnxOfflineTtsConfig(model: model, ruleFsts: rules, maxNumSentences: 1)
        let engine = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard engine.tts != nil else { throw OfflineSpeechError.modelMissing }
        return engine
    }

    private static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        ascii("RIFF"); u32(36 + byteCount); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); ascii("data"); u32(byteCount)
        for sample in samples {
            let scaled = Int16((min(max(sample, -1), 1) * 32767).rounded())
            u16(UInt16(bitPattern: scaled))
        }
        return data
    }

    private func fail(_ message: String) { stop(); onError?(message) }

    func pause() {
        intentionallyPaused = true
        if isNeuralVoice {
            player?.pause()
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    func resume() {
        guard intentionallyPaused else { return }
        intentionallyPaused = false
        if isNeuralVoice {
            if let player { player.play() }; pumpOffline()
        } else {
            synthesizer.continueSpeaking()
        }
    }

    func stop() {
        session.cancel()
        session = SpeechCancellation()
        intentionallyPaused = false
        player?.delegate = nil
        player?.stop()
        player = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        queue = []
        cursor = nil
        window = SpeechPrefetchWindow()
        ready.removeAll()
        sourceEnded = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeUtterance === utterance, self.queue.indices.contains(self.currentIndex) else { return }
            self.onSegmentStarted?(self.queue[self.currentIndex].id)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeUtterance === utterance, !self.intentionallyPaused else { return }
            self.activeUtterance = nil
            self.playNext()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        self.player = nil
        guard flag else { fail("离线语音播放被中断，请重试"); return }
        window.advance()
        pumpOffline()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        fail("离线语音解码失败\(error.map { "：\($0.localizedDescription)" } ?? "")")
    }

    private func playNext() {
        currentIndex += 1
        if currentIndex < queue.count { speakCurrent() } else { stop(); onQueueCompleted?() }
    }

    deinit {
        session.cancel()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
    }
}

// Called only on SystemSpeechEngine's shared serial synthesis queue.
// Loading is async in upstream; this bridge waits off the main thread.
private enum QwenOfflineRuntime {
    private static var model: Qwen3TTSModel?
    private final class LoadResult: @unchecked Sendable {
        var value: Result<Qwen3TTSModel, Error>?
    }
    static func release() {
        guard model != nil else { return }
        model = nil
        GPU.clearCache()
    }
    static func generate(text: String, reference: String, token: SpeechCancellation) throws -> [Float] {
        guard ["gentle", "coaxing"].contains(reference) else { throw OfflineSpeechError.invalidVoice }
        guard ProcessInfo.processInfo.physicalMemory >= 6_000_000_000 else {
            throw NSError(domain: "Qwen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Qwen 实验音色需要至少 6GB 内存的设备，请使用 Kokoro 或系统语音。"])
        }
        if token.isCancelled { throw CancellationError() }
        GPU.set(cacheLimit: 32 * 1024 * 1024)
        if model == nil {
            let path = Bundle.main.bundleURL.appendingPathComponent("QwenModel")
            guard FileManager.default.fileExists(atPath: path.appendingPathComponent("model.safetensors").path),
                  FileManager.default.fileExists(atPath: path.appendingPathComponent("speech_tokenizer/model.safetensors").path) else {
                throw NSError(domain: "Qwen", code: 2, userInfo: [NSLocalizedDescriptionKey: "此安装包未包含 Qwen 模型，请安装完整实验版；原有语音仍可使用。"])
            }
            let box = LoadResult()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                do { box.value = .success(try await Qwen3TTSModel.fromPretrained(path.path, shouldCancel: { token.isCancelled })) }
                catch { box.value = .failure(error) }
                semaphore.signal()
            }
            semaphore.wait()
            model = try box.value?.get()
        }
        if token.isCancelled { throw CancellationError() }
        guard let model, model.supportsVoiceCloning else { throw OfflineSpeechError.invalidVoice }
        let referenceURL = Bundle.main.bundleURL.appendingPathComponent("VoiceReferences/\(reference).wav")
        let (sampleRate, referenceAudio) = try loadAudioArray(from: referenceURL)
        guard sampleRate == 24_000 else { throw OfflineSpeechError.emptyAudio }
        let audio = try model.generateVoiceClone(
            text: text, referenceAudio: referenceAudio,
            referenceText: "你回来啦，今天辛苦了。要不要坐下来，让我陪你读一会儿书？别着急，今晚的故事，我们慢慢听。",
            language: "chinese", temperature: 0.7, maxTokens: 384,
            shouldCancel: { token.isCancelled }
        )
        if token.isCancelled { throw CancellationError() }
        let samples = audio.asArray(Float.self)
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw OfflineSpeechError.emptyAudio }
        return samples
    }
}

private enum OfflineSpeechError: LocalizedError {
    case modelMissing
    case emptyAudio
    case invalidVoice

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "安装包缺少 Kokoro 模型文件"
        case .emptyAudio: return "模型没有生成音频"
        case .invalidVoice: return "音色编号不受当前模型支持"
        }
    }
}
