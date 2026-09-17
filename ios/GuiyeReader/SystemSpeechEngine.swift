import AVFoundation
import Foundation
import SherpaOnnx

final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    private static let kokoroVoices = [
        SpeechVoice(id: "kokoro:3", name: "甜橙 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:8", name: "蜜桃 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:20", name: "月光 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:40", name: "清泉 · 中文女声", languageTag: "zh-CN", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:0", name: "Maple · 英语女声", languageTag: "en-US", quality: "开源神经", provider: "kokoro"),
        SpeechVoice(id: "kokoro:1", name: "Sol · 英语女声", languageTag: "en-US", quality: "开源神经", provider: "kokoro")
    ]

    private let synthesizer = AVSpeechSynthesizer()
    private let synthesisQueue = DispatchQueue(label: "com.guiye.reader.kokoro", qos: .userInitiated)
    private var offlineTts: SherpaOnnxOfflineTtsWrapper?
    private var queue: [SpeechSegment] = []
    private var currentIndex = 0
    private var voiceID: String?
    private var rate: Float = 0.5
    private var intentionallyPaused = false
    private var player: AVAudioPlayer?
    private var generation = 0

    var onSegmentStarted: ((Int) -> Void)?
    var onQueueCompleted: (() -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var voices: [SpeechVoice] {
        Self.kokoroVoices + AVSpeechSynthesisVoice.speechVoices()
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
        speakCurrent()
    }

    private func speakCurrent() {
        guard queue.indices.contains(currentIndex) else { onQueueCompleted?(); return }
        let segment = queue[currentIndex]
        if voiceID?.hasPrefix("kokoro:") == true {
            synthesizeOffline(segment)
            return
        }
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.12
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: segment.languageTag)
        synthesizer.speak(utterance)
    }

    private func synthesizeOffline(_ segment: SpeechSegment) {
        let requestGeneration = generation
        let sid = Int(voiceID?.replacingOccurrences(of: "kokoro:", with: "") ?? "3") ?? 3
        let speed = min(max(0.6 + (rate - 0.35) / 0.30, 0.6), 1.6)
        synthesisQueue.async { [weak self] in
            guard let self else { return }
            do {
                let engine: SherpaOnnxOfflineTtsWrapper
                if let existing = self.offlineTts {
                    engine = existing
                } else {
                    engine = try self.createOfflineTts()
                    self.offlineTts = engine
                }
                let audio = engine.generate(text: segment.text, sid: sid, speed: speed)
                guard !audio.samples.isEmpty else { throw OfflineSpeechError.emptyAudio }
                let data = Self.wavData(samples: audio.samples, sampleRate: Int(audio.sampleRate))
                DispatchQueue.main.async {
                    guard self.generation == requestGeneration, !self.intentionallyPaused else { return }
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                        try AVAudioSession.sharedInstance().setActive(true)
                        self.player = try AVAudioPlayer(data: data)
                        self.player?.delegate = self
                        self.player?.prepareToPlay()
                        self.onSegmentStarted?(segment.id)
                        self.player?.play()
                    } catch {
                        self.fail("离线语音播放失败：\(error.localizedDescription)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.generation == requestGeneration && !self.intentionallyPaused {
                        self.fail("离线语音初始化失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func createOfflineTts() throws -> SherpaOnnxOfflineTtsWrapper {
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
        return SherpaOnnxOfflineTtsWrapper(config: &config)
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

    private func fail(_ message: String) { player?.stop(); player = nil; onError?(message) }

    func pause() {
        intentionallyPaused = true
        if voiceID?.hasPrefix("kokoro:") == true {
            if player == nil { generation += 1 } else { player?.pause() }
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    func resume() {
        guard intentionallyPaused else { return }
        intentionallyPaused = false
        if voiceID?.hasPrefix("kokoro:") == true {
            if let player { player.play() } else { speakCurrent() }
        } else {
            synthesizer.continueSpeaking()
        }
    }

    func stop() {
        generation += 1
        intentionallyPaused = false
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSegmentStarted?(queue[currentIndex].id)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !intentionallyPaused else { return }
        playNext()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        guard flag, !intentionallyPaused else { return }
        playNext()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        fail("离线语音解码失败\(error.map { "：\($0.localizedDescription)" } ?? "")")
    }

    private func playNext() {
        currentIndex += 1
        if currentIndex < queue.count { speakCurrent() } else { onQueueCompleted?() }
    }
}

private enum OfflineSpeechError: LocalizedError {
    case modelMissing
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "安装包缺少 Kokoro 模型文件"
        case .emptyAudio: return "模型没有生成音频"
        }
    }
}
