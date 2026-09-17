import AVFoundation
import Foundation
import Security

private struct SpeechAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private final class SpeechSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum RemoteSpeechSettings {
    static var address: String {
        get { UserDefaults.standard.string(forKey: "speech.api.address") ?? "https://sy.360427.xyz:16666" }
        set { UserDefaults.standard.set(newValue, forKey: "speech.api.address") }
    }
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.guiye.reader.tts", kSecAttrAccount as String: "api-key"]
    static var key: String {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw SpeechAPIError(message: "请输入有效 HTTPS 地址，不含密钥或查询参数") }
        let base = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base.hasSuffix("/v1/audio/speech") ? base : base + "/v1/audio/speech")!
    }
    static func save(address value: String, key: String) throws {
        _ = try endpoint(value)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw SpeechAPIError(message: "请填写 API 密钥") }
        let attrs: [String: Any] = [kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(query.merging(attrs) { _, n in n } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw SpeechAPIError(message: "密钥保存失败") }
        address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let system = AVSpeechSynthesizer()
    private let delegate = SpeechSessionDelegate()
    private lazy var client: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 330
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private var generation: Task<Void, Never>?
    private var generationID = UUID()
    private var player: AVAudioPlayer?
    private var activeUtterance: AVSpeechUtterance?
    private var queue: [SpeechSegment] = []
    private var index = 0
    private var voiceID: String?
    private var rate: Float = 0.5
    private var paused = false
    private var ready: [(SpeechSegment, Data)] = []
    private var ended = false
    var onSegmentStarted: ((Int) -> Void)?
    var onQueueCompleted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?

    override init() { super.init(); system.delegate = self }
    lazy var voices: [SpeechVoice] = [
        SpeechVoice(id: "api:1", name: "温柔自然 · 1号", languageTag: "zh-CN", quality: "远程 API", isNetworkRequired: true, provider: "api"),
        SpeechVoice(id: "api:4", name: "温柔微嗲 · 4号", languageTag: "zh-CN", quality: "远程 API", isNetworkRequired: true, provider: "api")
    ] + AVSpeechSynthesisVoice.speechVoices().map {
        SpeechVoice(id: $0.identifier, name: $0.name, languageTag: $0.language,
                    quality: $0.quality == .premium ? "Premium" : ($0.quality == .enhanced ? "增强" : "标准"))
    }
    func speak(segments: [SpeechSegment], from index: Int, voiceID: String?, rate: Float) {
        stop()
        guard !segments.isEmpty else { return }
        queue = segments; self.index = min(max(0, index), segments.count - 1)
        self.voiceID = voiceID; self.rate = rate
        if voiceID?.hasPrefix("api:") != true { speakSystem(); return }
        let id = generationID
        let voice = voiceID == "api:4" ? "4" : "1"
        let address = RemoteSpeechSettings.address, key = RemoteSpeechSettings.key
        var cursor = SpeechChunkCursor(segments: segments, from: self.index)
        onStatus?("正在准备远程语音，可继续阅读；NAS 生成可能需要几十秒")
        generation = Task { @MainActor [weak self] in
            do {
                guard !key.isEmpty else { throw SpeechAPIError(message: "请先在智能语音中保存 API 密钥") }
                let url = try RemoteSpeechSettings.endpoint(address)
                while let segment = cursor.next() {
                    try Task.checkCancellation()
                    // Bound audio memory to current playback plus two prepared chunks.
                    while let owner = self, owner.ready.count >= 2 || owner.paused {
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    guard let owner = self, owner.generationID == id else { return }
                    var request = URLRequest(url: url, timeoutInterval: 300)
                    request.httpMethod = "POST"
                    request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": "qwen3-tts-0.6b", "input": segment.text, "voice": voice, "response_format": "wav", "speed": 1])
                    var audio: Data?
                    for attempt in 0..<16 {
                        let (file, response) = try await owner.client.download(for: request)
                        defer { try? FileManager.default.removeItem(at: file) }
                        try Task.checkCancellation()
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 429 && attempt < 15 { try await Task.sleep(nanoseconds: 2_000_000_000); continue }
                        guard status == 200 else { throw SpeechAPIError(message: status == 401 ? "API 密钥无效" : "语音服务暂不可用（HTTP " + String(status) + "），可切换系统语音") }
                        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 44, size <= 8 * 1024 * 1024 else { throw SpeechAPIError(message: "音频大小异常") }
                        let data = try Data(contentsOf: file, options: .mappedIfSafe)
                        guard data.count > 44, data.count <= 8 * 1024 * 1024,
                              String(data: data.prefix(4), encoding: .ascii) == "RIFF" else { throw SpeechAPIError(message: "返回的音频格式无效") }
                        audio = data; break
                    }
                    guard owner.generationID == id, let audio else { return }
                    owner.ready.append((segment, audio)); owner.playReady()
                }
                guard let owner = self, owner.generationID == id else { return }
                owner.ended = true; owner.playReady()
            } catch {
                guard !Task.isCancelled, let owner = self, owner.generationID == id else { return }
                owner.stop(); owner.onError?(error.localizedDescription)
            }
        }
    }
    private func speakSystem() {
        guard queue.indices.contains(index) else { stop(); onQueueCompleted?(); return }
        let u = AVSpeechUtterance(string: queue[index].text)
        u.rate = rate
        u.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: detectedLanguage(for: queue[index].text))
        activeUtterance = u; system.speak(u)
    }
    private func playReady() {
        guard !paused, player == nil else { return }
        guard !ready.isEmpty else {
            if ended { stop(); onQueueCompleted?() }
            else { onStatus?("等待下一段语音，可继续阅读或暂停") }
            return
        }
        let (segment, data) = ready.removeFirst()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(data: data)
            next.delegate = self; next.enableRate = true
            next.rate = min(max(0.6 + (rate - 0.35) / 0.30, 0.6), 1.6)
            player = next
            guard next.play() else { throw SpeechAPIError(message: "音频无法播放") }
            onStatus?(nil); onSegmentStarted?(segment.id)
        } catch { stop(); onError?(error.localizedDescription) }
    }
    func pause() { paused = true; player?.pause(); system.pauseSpeaking(at: .word) }
    func resume() {
        paused = false
        if voiceID?.hasPrefix("api:") == true { if let player { player.play() } else { playReady() } }
        else { system.continueSpeaking() }
    }
    func stop() {
        generationID = UUID(); generation?.cancel(); generation = nil
        player?.delegate = nil; player?.stop(); player = nil
        activeUtterance = nil; system.stopSpeaking(at: .immediate)
        ready.removeAll(); queue.removeAll(); paused = false; ended = false; onStatus?(nil)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance, queue.indices.contains(index) else { return }
        onSegmentStarted?(queue[index].id)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        index += 1; speakSystem()
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        self.player = nil
        if flag { playReady() } else { stop(); onError?("语音播放中断") }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        stop(); onError?("音频解码失败")
    }
    deinit { generation?.cancel() }
}
