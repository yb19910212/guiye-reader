#if QWEN_LAB
import SwiftUI
import AVFoundation
import CryptoKit
import MLX
import Qwen3TTS

private func labError(_ message: String) -> NSError {
    NSError(domain: "OfflineVoiceLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private final class LabCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

private struct LabManifest: Decodable {
    struct Entry: Decodable { let path: String; let sha256: String; let url: String? }
    let revision: String
    let files: [Entry]
}

private final class LabDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (String) -> Void
    let name: String
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    init(name: String, report: @escaping @Sendable (String) -> Void) { self.name = name; self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= 0.25 else { lock.unlock(); return }
        lastUpdate = now; lock.unlock()
        let done = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        let total = totalBytesExpectedToWrite > 0 ? ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file) : "未知大小"
        report("下载 \(name)：\(done) / \(total)")
    }
}

// One worker owns all MLX state. No model creation, hashing or inference on MainActor.
private actor OfflineLabWorker {
    static let shared = OfflineLabWorker()
    private var model: Qwen3TTSModel?
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QwenLab-0d6bb6fe-v1", isDirectory: true)

    private func hash(_ file: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var digest = SHA256()
        while let block = try stream.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            digest.update(data: block)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func prepare(report: @escaping @Sendable (String) -> Void) async throws {
        let support = Bundle.main.bundleURL.appendingPathComponent("QwenSupport")
        let manifest = try JSONDecoder().decode(LabManifest.self, from: Data(contentsOf: support.appendingPathComponent("manifest.json")))
        guard manifest.revision == "0d6bb6fe33f92d47a507e23b9148940e8366ab5b" else { throw labError("模型版本不匹配") }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(excluded)
        for entry in manifest.files {
            try Task.checkCancellation()
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { throw labError("非法模型路径") }
            let target = directory.appendingPathComponent(entry.path)
            report("校验 \(entry.path)")
            if manager.fileExists(atPath: target.path), try hash(target) == entry.sha256 { continue }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let address = entry.url {
                guard let url = URL(string: address), url.scheme == "https", url.host == "huggingface.co" else { throw labError("模型下载地址无效") }
                let delegate = LabDownloadProgress(name: entry.path, report: report)
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
                defer { try? manager.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw labError("模型下载失败，请检查网络后重试") }
                report("验证下载文件 \(entry.path)")
                guard try hash(temporary) == entry.sha256 else { throw labError("模型校验失败：\(entry.path)，请重新下载") }
                try Task.checkCancellation()
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.moveItem(at: temporary, to: target)
            } else {
                let source = support.appendingPathComponent(entry.path)
                guard try hash(source) == entry.sha256 else { throw labError("安装包资源损坏：\(entry.path)") }
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: source, to: target)
            }
        }
        guard manager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) else { throw labError("缺少 tokenizer.json") }
    }

    struct Result: Sendable { let file: URL; let load: Double; let generate: Double; let audio: Double }
    func test(reference: String, text: String, cancellation: LabCancellation,
              report: @escaping @Sendable (String) -> Void) async throws -> Result {
        guard ["gentle", "coaxing"].contains(reference) else { throw labError("无效音色") }
        guard ProcessInfo.processInfo.physicalMemory >= 6_000_000_000 else { throw labError("实验模型至少需要 6 GB 设备内存，请继续使用 API 或系统语音") }
        let start = Date()
        let cancelled = { cancellation.cancelled || Date().timeIntervalSince(start) > 120 }
        guard !cancelled() else { throw CancellationError() }
        GPU.set(cacheLimit: 32 * 1024 * 1024)
        report(model == nil ? "检查分词器并加载模型（首次较慢）" : "复用已加载模型")
        if model == nil { model = try await Qwen3TTSModel.fromPretrained(directory.path, shouldCancel: cancelled) }
        guard !cancelled(), let model else { throw CancellationError() }
        let load = Date().timeIntervalSince(start)
        let (rate, referenceAudio) = try loadAudioArray(from: Bundle.main.bundleURL.appendingPathComponent("VoiceReferences/\(reference).wav"))
        guard rate == 24_000 else { throw labError("参考录音采样率不匹配") }
        report("生成语音：0 帧")
        var frames = 0
        let generatedAt = Date()
        let audio = try model.generateVoiceClone(text: text, referenceAudio: referenceAudio,
            referenceText: "你回来啦，今天辛苦了。要不要坐下来，让我陪你读一会儿书？别着急，今晚的故事，我们慢慢听。",
            language: "chinese", temperature: 0.7, maxTokens: 192,
            onToken: { _ in frames += 1; if frames % 8 == 0 { report("生成语音：\(frames) 帧（不是下载进度）") } },
            shouldCancel: cancelled)
        guard !cancelled() else { throw CancellationError() }
        guard frames < 192 else { throw labError("达到测试生成上限，未播放可能截断的音频；请缩短测试句") }
        let samples = audio.asArray(Float.self)
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw labError("模型返回无效音频") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("guiye-offline-lab.wav")
        try saveAudioArray(audio, sampleRate: 24_000, to: output)
        return Result(file: output, load: load, generate: Date().timeIntervalSince(generatedAt), audio: Double(samples.count) / 24_000)
    }
    func release() { model = nil; GPU.clearCache() }
}

@MainActor
private final class OfflineLabState: ObservableObject {
    // Reopening the sheet cannot create a second model or overlapping generation.
    static let shared = OfflineLabState()
    @Published var status = "尚未加载模型；正常阅读与 API 不受影响"
    @Published var busy = false
    @Published var ready = false
    @Published var startedAt = Date()
    @Published var result = ""
    private var task: Task<Void, Never>?
    private var cancellation = LabCancellation()
    private var player: AVAudioPlayer?

    func prepare() { begin { report, _ in
        try await OfflineLabWorker.shared.prepare(report: report)
        return nil
    } }
    func test(reference: String, text: String) {
        guard ready else { status = "请先下载并校验模型"; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 40 else { status = "请输入 1–40 字测试句"; return }
        guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { status = "设备温度较高，请降温后再试"; return }
        begin { report, token in try await OfflineLabWorker.shared.test(reference: reference, text: text, cancellation: token, report: report) }
    }
    private func begin(_ operation: @escaping @Sendable (@escaping @Sendable (String) -> Void, LabCancellation) async throws -> OfflineLabWorker.Result?) {
        guard !busy else { return }
        player?.stop(); player = nil; busy = true; result = ""; startedAt = Date()
        cancellation = LabCancellation()
        let token = cancellation
        task = Task {
            do {
                let output = try await operation({ message in Task { @MainActor in
                    guard !token.cancelled else { return }; self.status = message
                } }, token)
                try Task.checkCancellation()
                guard !token.cancelled else { throw CancellationError() }
                if let output {
                    result = String(format: "模型加载 %.1f 秒 · 生成 %.1f 秒 · 音频 %.1f 秒\n生成耗时/音频时长 %.2f（小于 1 才有连续播放的基础）", output.load, output.generate, output.audio, output.generate / output.audio)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    player = try AVAudioPlayer(contentsOf: output.file)
                    guard player?.play() == true else { throw labError("音频播放失败") }
                    status = "生成完成，正在试听；可切换音色重测"
                } else { ready = true; status = "模型完整性校验通过，可断网测试 1 号 / 4 号" }
            } catch {
                await OfflineLabWorker.shared.release()
                status = token.cancelled || Task.isCancelled ? "已取消并释放模型" : "测试失败：\(error.localizedDescription)"
            }
            token.cancel() // Discard late progress callbacks from the completed operation.
            busy = false; task = nil
        }
    }
    func stop() {
        player?.stop(); player = nil
        cancellation.cancel(); task?.cancel()
        if busy { status = "正在取消，等待当前计算安全退出…" }
        else {
            busy = true
            task = Task { await OfflineLabWorker.shared.release(); status = "已释放模型；正常阅读不加载离线引擎"; busy = false; task = nil }
        }
    }
}

struct OfflineVoiceLab: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = OfflineLabState.shared
    @State private var reference = "coaxing"
    @State private var text = "别着急，让我陪你慢慢读，好不好？"
    var body: some View {
        NavigationStack {
            Form {
                Section("独立实验，不接管阅读器") {
                    Text("首次需联网下载 Qwen 0.6B 四位量化模型，建议 Wi-Fi 并预留 2 GB 空间。文件校验后可断网试听；不会上传正文。仅限前台，尚未通过真机性能验收。")
                    Button("下载 / 重新校验模型") { state.prepare() }.disabled(state.busy)
                }
                Section("短句测试") {
                    Picker("参考音色", selection: $reference) {
                        Text("温柔自然 · 1号").tag("gentle")
                        Text("温柔微嗲 · 4号").tag("coaxing")
                    }.disabled(state.busy)
                    TextField("1–40 字", text: $text, axis: .vertical).disabled(state.busy)
                    Button("在本机生成并试听") { state.test(reference: reference, text: text) }.disabled(state.busy || !state.ready)
                    Button("取消 / 停止并释放模型", role: .destructive) { state.stop() }
                }
                Section("实时状态") {
                    Text(state.status).textSelection(.enabled)
                    if state.busy {
                        ProgressView()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("已等待 \(Int(context.date.timeIntervalSince(state.startedAt))) 秒")
                        }
                    }
                    if !state.result.isEmpty { Text(state.result).textSelection(.enabled) }
                }
            }
            .navigationTitle("离线语音实验室")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { state.stop(); dismiss() } } }
        }
        .onDisappear { state.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { state.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in state.stop() }
    }
}
#endif
