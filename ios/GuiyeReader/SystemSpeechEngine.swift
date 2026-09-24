import AVFoundation
import Foundation
import Security
import CryptoKit
import UIKit

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
    private var playerFile: URL?
    private var pendingFailure: String?
    private var activeUtterance: AVSpeechUtterance?
    private var queue: [SpeechSegment] = []
    private var index = 0
    private var voiceID: String?
    private var rate: Float = 0.5
    private var paused = false
    private var ready: [(SpeechSegment, URL)] = []
    private var preparing = false
    private var progress = SpeechProgress()
    private var preroll = SpeechPreroll()
    private var isLocal: Bool { voiceID?.hasPrefix("qwen:") == true }
#if QWEN_LAB
    private var localCancellation: LabCancellation?
    private var observers: [NSObjectProtocol] = []
#endif
    var onProgress: ((SpeechProgress?) -> Void)?
    var playbackTime: String { guard let player else { return "" }; return String(format: "播放 %.0f / %.0f 秒", player.currentTime, player.duration) }
    func setRate(_ value: Float) { rate = value; player?.rate = min(max(0.6 + (rate - 0.35) / 0.30, 0.6), 1.6) }
    func clearCache() { stop(); generation = Task { @MainActor in do { try await SpeechDiskCache.shared.clear(); onStatus?("语音缓存已清理") } catch { onError?("清理缓存失败") } } }
    func prepareChapter(segments: [SpeechSegment], voiceID: String?, rate: Float) {
        start(segments: segments, from: 0, voiceID: voiceID, rate: rate, chapter: true)
    }
    private var ended = false
    var onSegmentStarted: ((Int) -> Void)?
    var onQueueCompleted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?

    override init() {
        super.init(); system.delegate = self
#if QWEN_LAB
        for notification in [UIApplication.willResignActiveNotification, UIApplication.didReceiveMemoryWarningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isLocal, !self.queue.isEmpty else { return }
                if notification == UIApplication.didReceiveMemoryWarningNotification {
                    self.drainAfterFailure("收到 iOS 内存警告（\(localSpeechFootprint())）：已取消生成，等待计算退出后释放模型；已备音频播放后暂停，缓存和位置保留。不必清理磁盘缓存。")
                } else {
                    self.stop()
                    self.onError?("应用失去前台活动状态，本地推理已停止；缓存保留。此提示不是内存警告。")
                }
            })
        }
#endif
    }
    private var localVoices: [SpeechVoice] {
#if QWEN_LAB
        return [
            SpeechVoice(id: "qwen:gentle", name: "温柔自然 · 1号（本地）", languageTag: "zh-CN", quality: "离线实验版", provider: "qwen"),
            SpeechVoice(id: "qwen:coaxing", name: "温柔微嗲 · 4号（本地）", languageTag: "zh-CN", quality: "离线实验版", provider: "qwen")
        ]
#else
        return []
#endif
    }
    lazy var voices: [SpeechVoice] = localVoices + [
        SpeechVoice(id: "api:1", name: "温柔自然 · 1号", languageTag: "zh-CN", quality: "远程 API", isNetworkRequired: true, provider: "api"),
        SpeechVoice(id: "api:4", name: "温柔微嗲 · 4号", languageTag: "zh-CN", quality: "远程 API", isNetworkRequired: true, provider: "api")
    ] + AVSpeechSynthesisVoice.speechVoices().map {
        SpeechVoice(id: $0.identifier, name: $0.name, languageTag: $0.language,
                    quality: $0.quality == .premium ? "Premium" : ($0.quality == .enhanced ? "增强" : "标准"))
    }
    func speak(segments: [SpeechSegment], from index: Int, voiceID: String?, rate: Float) {
        start(segments: segments, from: index, voiceID: voiceID, rate: rate, chapter: false)
    }
    private func start(segments: [SpeechSegment], from index: Int, voiceID: String?, rate: Float, chapter: Bool) {
        stop()
        guard !segments.isEmpty else { return }
        queue = segments; self.index = min(max(0, index), segments.count - 1)
        self.voiceID = voiceID; self.rate = rate
#if QWEN_LAB
        if isLocal { startLocal(segments: segments, chapter: chapter); return }
#endif
        if voiceID?.hasPrefix("api:") != true { speakSystem(); return }
        let id = generationID
        let voice = voiceID == "api:4" ? "4" : "1"
        let address = RemoteSpeechSettings.address, key = RemoteSpeechSettings.key
        var cursor = SpeechChunkCursor(segments: segments, from: self.index)
        preparing = chapter
        progress = SpeechProgress()
        progress.preparingChapter = chapter
        if chapter {
            var counter = cursor
            while counter.next() != nil { progress.total += 1; if progress.total > 1000 { stop(); onError?("本章过长，请选择较短章节或逐段朗读"); return } }
        }
        onProgress?(progress)
        onStatus?(chapter ? "本章音频全部缓存后自动播放；取消后可复用已完成缓存" : "边生成边听，生成较慢时会等待")
        generation = Task { @MainActor [weak self] in
            do {
                guard !key.isEmpty else { throw SpeechAPIError(message: "请先在智能语音中保存 API 密钥") }
                let url = try RemoteSpeechSettings.endpoint(address)
                while let segment = cursor.next() {
                    try Task.checkCancellation()
                    // Bound audio memory to current playback plus two prepared chunks.
                    while let owner = self, (!chapter && owner.ready.count >= 2) || owner.paused {
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    guard let owner = self, owner.generationID == id else { return }
                    owner.progress.phase = "检查本机缓存"
                    owner.progress.requestStartedAt = Date()
                    owner.onProgress?(owner.progress)
                    let identity = String(data: try JSONSerialization.data(withJSONObject: ["sentence-v2", "qwen3-tts-0.6b", url.absoluteString, key, voice, segment.text]), encoding: .utf8)!
                    let cachedFile = try await SpeechDiskCache.shared.file(identity: identity)
                    if let duration = await SpeechDiskCache.shared.read(cachedFile) {
                        try Task.checkCancellation()
                        owner.accept(segment, file: cachedFile, duration: duration, cached: true)
                        continue
                    }
                    owner.progress.phase = "等待服务器生成 / 下载"
                    owner.onProgress?(owner.progress)
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
                        if status == 429 && attempt < 15 { owner.progress.phase = "服务器繁忙，排队重试"; owner.onProgress?(owner.progress); try await Task.sleep(nanoseconds: 2_000_000_000); continue }
                        guard status == 200 else { throw SpeechAPIError(message: status == 401 ? "API 密钥无效" : "语音服务暂不可用（HTTP " + String(status) + "），可切换系统语音") }
                        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 44, size <= 8 * 1024 * 1024 else { throw SpeechAPIError(message: "音频大小异常") }
                        let data = try Data(contentsOf: file, options: .mappedIfSafe)
                        guard data.count > 44, data.count <= 8 * 1024 * 1024,
                              String(data: data.prefix(4), encoding: .ascii) == "RIFF" else { throw SpeechAPIError(message: "返回的音频格式无效") }
                        audio = data; break
                    }
                    guard owner.generationID == id, let audio else { return }
                    owner.progress.phase = "校验并保存音频"
                    owner.onProgress?(owner.progress)
                    let duration = try await SpeechDiskCache.shared.save(audio, to: cachedFile, protecting: owner.protectedFiles)
                    try Task.checkCancellation()
                    owner.accept(segment, file: cachedFile, duration: duration, cached: false)
                }
                guard let owner = self, owner.generationID == id else { return }
                owner.ended = true; owner.preparing = false; owner.progress.preparingChapter = false; owner.progress.requestStartedAt = nil; owner.playReady()
            } catch {
                guard !Task.isCancelled, let owner = self, owner.generationID == id else { return }
                var failed = owner.progress; failed.phase = "失败，可重试；已完成缓存保留"; failed.requestStartedAt = nil; failed.measuredAt = Date()
                owner.stop(); owner.onProgress?(failed); owner.onError?(error.localizedDescription)
            }
        }
    }
#if QWEN_LAB
    private func startLocal(segments: [SpeechSegment], chapter: Bool) {
        let id = generationID
        let token = LabCancellation(); localCancellation = token
        let reference = voiceID == "qwen:coaxing" ? "coaxing" : "gentle"
        var cursor = SpeechChunkCursor(segments: segments, from: index, maxCharacters: 24)
        preroll = SpeechPreroll(required: 1); preparing = chapter
        progress = SpeechProgress(); progress.preparingChapter = chapter
        if chapter {
            var counter = cursor
            while counter.next() != nil {
                progress.total += 1
                if progress.total > 1000 { stop(); onError?("本章过长，请逐段朗读或选择较短章节"); return }
            }
        }
        onProgress?(progress)
        onStatus?(chapter ? "稳定模式缓存整章：每段生成后释放模型；请保持前台" : "稳定模式：每段生成后释放模型，先准备一段播放；可能短暂等待")
        generation = Task { @MainActor [weak self] in
            do {
                while let segment = cursor.next() {
                    try Task.checkCancellation()
                    while let owner = self, (!chapter && owner.ready.count >= 1) || owner.paused {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard let owner = self, owner.generationID == id, !token.cancelled else { return }
                    owner.progress.phase = "检查本地音频缓存"
                    owner.progress.requestStartedAt = Date(); owner.onProgress?(owner.progress)
                    // Independent from remote API identity; version includes all synthesis settings.
                    let identity = String(data: try JSONSerialization.data(withJSONObject:
                        ["ios-qwen-pcm16-v2-24chars-stable-temp0.7-max384", "0d6bb6fe33f92d47a507e23b9148940e8366ab5b", reference, segment.text]), encoding: .utf8)!
                    let file = try await SpeechDiskCache.shared.file(identity: identity)
                    let cachedDuration = await SpeechDiskCache.shared.read(file)
                    try Task.checkCancellation()
                    guard owner.generationID == id, !token.cancelled else { return }
                    if let duration = cachedDuration {
                        owner.accept(segment, file: file, duration: duration, cached: true)
                        continue
                    }
                    guard UIApplication.shared.applicationState == .active else { throw SpeechAPIError(message: "本地语音需要保持应用在前台") }
                    guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else {
                        throw SpeechAPIError(message: "设备温度较高，已停止本地生成；缓存保留，请降温后继续")
                    }
                    let output = try await OfflineLabWorker.shared.test(reference: reference, text: segment.text, cancellation: token, keepModel: false) { message in
                        Task { @MainActor [weak self] in
                            guard let owner = self, owner.generationID == id, !token.cancelled else { return }
                            owner.progress.phase = message; owner.onProgress?(owner.progress)
                        }
                    }
                    try Task.checkCancellation()
                    guard owner.generationID == id, !token.cancelled else { return }
                    let duration = try await SpeechDiskCache.shared.save(output.data, to: file, protecting: owner.protectedFiles)
                    try Task.checkCancellation()
                    guard owner.generationID == id, !token.cancelled else { return }
                    owner.progress.localTiming = String(format: "最近生成 %.1f 秒 / 音频 %.1f 秒 · 耗时比 %.2f · 加载 %.1f 秒\n", output.generate, output.audio, output.generate / max(0.01, output.audio), output.load) + output.memory
                    owner.accept(segment, file: file, duration: duration, cached: false)
                }
                guard let owner = self, owner.generationID == id, !token.cancelled else { return }
                owner.ended = true; owner.preparing = false; owner.progress.preparingChapter = false
                owner.progress.requestStartedAt = nil; owner.playReady()
            } catch {
                guard !Task.isCancelled, !token.cancelled, let owner = self, owner.generationID == id else { return }
                owner.drainAfterFailure(error.localizedDescription)
            }
        }
    }
#endif
    private var protectedFiles: Set<URL> {
        Set(ready.map { $0.1 } + (playerFile.map { [$0] } ?? []))
    }
    private func drainAfterFailure(_ message: String) {
#if QWEN_LAB
        localCancellation?.cancel()
        localCancellation = nil
        Task { await OfflineLabWorker.shared.release() }
#endif
        generationID = UUID(); generation?.cancel(); generation = nil
        pendingFailure = message; ended = true; preparing = false
        progress.preparingChapter = false; progress.requestStartedAt = nil
        progress.phase = "生成已停止；播放已备音频后暂停"; progress.measuredAt = Date()
        onProgress?(progress); onStatus?(message)
        playReady()
    }
    private func accept(_ segment: SpeechSegment, file: URL, duration: Double, cached: Bool) {
        progress.completed += 1; progress.cached += cached ? 1 : 0
        progress.characters += segment.text.count; progress.audioSeconds += duration
        progress.requestStartedAt = nil; progress.measuredAt = Date()
        progress.phase = paused ? "已暂停" : (preparing ? "缓存本章中" : "音频已准备")
        ready.append((segment, file)); onProgress?(progress); playReady()
    }
    private func speakSystem() {
        guard queue.indices.contains(index) else { stop(); onQueueCompleted?(); return }
        let u = AVSpeechUtterance(string: queue[index].text)
        u.rate = rate
        u.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: detectedLanguage(for: queue[index].text))
        activeUtterance = u; system.speak(u)
    }
    private func playReady() {
        guard !preparing, !paused, player == nil else { return }
        if isLocal && !preroll.canPlay(ready: ready.count, ended: ended) && !(ended && ready.isEmpty) {
            onStatus?("稳定模式正在准备下一段；模型会逐段释放，可能短暂等待。")
            return
        }
        guard !ready.isEmpty else {
            if ended {
                let failure = pendingFailure
                stop()
                if let failure { onError?(failure) } else { onQueueCompleted?() }
            }
            else { onStatus?("等待下一段语音，可继续阅读或暂停") }
            return
        }
        let (segment, file) = ready.removeFirst()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: file)
            next.delegate = self; next.enableRate = true
            next.rate = min(max(0.6 + (rate - 0.35) / 0.30, 0.6), 1.6)
            player = next
            playerFile = file
            guard next.play() else { throw SpeechAPIError(message: "音频无法播放") }
            progress.phase = "正在播放"; progress.played += 1; onProgress?(progress)
            onStatus?(pendingFailure); onSegmentStarted?(segment.id)
        } catch { stop(); onError?(error.localizedDescription) }
    }
    func pause() { paused = true; progress.phase = "已暂停（当前请求可能仍在完成）"; onProgress?(progress); player?.pause(); system.pauseSpeaking(at: .word) }
    func resume() {
        paused = false
        progress.phase = preparing ? "继续缓存本章" : "继续播放"; onProgress?(progress)
        if voiceID?.hasPrefix("api:") == true || isLocal { if let player { player.play() } else { playReady() } }
        else { system.continueSpeaking() }
    }
    func stop() {
#if QWEN_LAB
        if let token = localCancellation {
            token.cancel(); localCancellation = nil
            Task { await OfflineLabWorker.shared.release() }
        }
#endif
        generationID = UUID(); generation?.cancel(); generation = nil
        player?.delegate = nil; player?.stop(); player = nil
        playerFile = nil; pendingFailure = nil
        activeUtterance = nil; system.stopSpeaking(at: .immediate)
        ready.removeAll(); queue.removeAll(); paused = false; ended = false; preparing = false; onProgress?(nil); onStatus?(nil)
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
        playerFile = nil
        if flag { playReady() } else { stop(); onError?("语音播放中断") }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        stop(); onError?("音频解码失败")
    }
    deinit {
        generation?.cancel()
#if QWEN_LAB
        localCancellation?.cancel()
        if localCancellation != nil { Task { await OfflineLabWorker.shared.release() } }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
#endif
    }
}
