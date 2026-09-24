#if QWEN_LAB
import SwiftUI
import AVFoundation
import CryptoKit
import MLX
import Qwen3TTS
import UniformTypeIdentifiers
import Darwin

func localSpeechFootprint() -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? String(format: "App 内存 %.0f MB", Double(info.phys_footprint) / 1_048_576) : "App 内存不可用"
}

private func labError(_ message: String) -> NSError {
    NSError(domain: "OfflineVoiceLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private var hasBundledLabModel: Bool {
    OfflineModelFiles.paths.allSatisfy {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("QwenSupport/\($0)").path)
    }
}

final class LabCancellation: @unchecked Sendable {
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
actor OfflineLabWorker {
    static let shared = OfflineLabWorker()
    private var model: Qwen3TTSModel?
    private var generating = false
    private var releaseRequested = false
    private var verified = false
    private let importedDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QwenLab-0d6bb6fe-v1", isDirectory: true)
    private var directory: URL {
        hasBundledLabModel ? Bundle.main.bundleURL.appendingPathComponent("QwenSupport") : importedDirectory
    }

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

    func prepare(source: String = "official", custom: String = "", download: Bool = true,
                 report: @escaping @Sendable (String) -> Void) async throws {
        let support = Bundle.main.bundleURL.appendingPathComponent("QwenSupport")
        let manifest = try JSONDecoder().decode(LabManifest.self, from: Data(contentsOf: support.appendingPathComponent("manifest.json")))
        guard manifest.revision == "0d6bb6fe33f92d47a507e23b9148940e8366ab5b" else { throw labError("模型版本不匹配") }
        if hasBundledLabModel {
            // Read-only verification in the app bundle: no copying and no network.
            for entry in manifest.files {
                try Task.checkCancellation()
                report("校验内置资源 \(entry.path)（无需联网）")
                guard try hash(support.appendingPathComponent(entry.path)) == entry.sha256 else {
                    throw labError("内置模型损坏：\(entry.path)。请重新安装完整包，无需在应用内下载。")
                }
            }
            verified = true
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(excluded)
        var missing: [String] = []
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for entry in manifest.files {
            try Task.checkCancellation()
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { throw labError("非法模型路径") }
            let target = directory.appendingPathComponent(entry.path)
            report("校验 \(entry.path)")
            if manager.fileExists(atPath: target.path), try hash(target) == entry.sha256 { continue }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.url != nil {
                guard download else { missing.append(entry.path); continue }
                let url = try OfflineModelFiles.sourceURL(path: entry.path, source: source, custom: custom)
                for attempt in 1...2 {
                    try Task.checkCancellation()
                    report("正在连接 \(url.host ?? "下载源") · \(entry.path)（第 \(attempt)/2 次，连续 30 秒无数据将超时）")
                    do {
                        let delegate = LabDownloadProgress(name: entry.path, report: report)
                        let (temporary, response) = try await session.download(from: url, delegate: delegate)
                        defer { try? manager.removeItem(at: temporary) }
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard code == 200 else { throw labError("下载源返回 HTTP \(code)，请更换下载源或导入文件") }
                        report("校验并安装 \(entry.path)")
                        try OfflineModelFiles.install(from: temporary, to: target, expectedHash: entry.sha256,
                            cancelled: { Task.isCancelled }, report: { _ in })
                        break
                    } catch {
                        try Task.checkCancellation()
                        if let failure = error as? URLError {
                            if attempt < 2 && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(failure.code) {
                                report("连接失败，2 秒后重试；也可以取消并换源")
                                try await Task.sleep(for: .seconds(2))
                                continue
                            }
                            throw labError("下载连接失败（\(failure.code.rawValue)）：\(failure.localizedDescription)。蜂窝网络可用，请检查归页联网权限，或换源/从文件导入。")
                        }
                        throw error
                    }
                }
            } else {
                let source = support.appendingPathComponent(entry.path)
                guard try hash(source) == entry.sha256 else { throw labError("安装包资源损坏：\(entry.path)") }
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: source, to: target)
            }
        }
        guard missing.isEmpty else { throw labError("已保存并校验完成的文件；仍缺少：\(missing.joined(separator: "、"))。请继续导入另一个文件，或选择下载源补齐。") }
        guard manager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) else { throw labError("缺少 tokenizer.json") }
    }

    func importFile(_ url: URL, path: String, report: @escaping @Sendable (String) -> Void) async throws {
        guard !hasBundledLabModel else { throw labError("完整内置版无需导入，请校验内置模型") }
        guard !generating else { throw labError("请先停止正文朗读，再导入模型") }
        verified = false
        release()
        guard OfflineModelFiles.paths.contains(path) else { throw labError("无效模型类型") }
        let support = Bundle.main.bundleURL.appendingPathComponent("QwenSupport")
        let manifest = try JSONDecoder().decode(LabManifest.self, from: Data(contentsOf: support.appendingPathComponent("manifest.json")))
        guard let entry = manifest.files.first(where: { $0.path == path }) else { throw labError("缺少模型校验信息") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        report("等待文件提供器准备 \(url.lastPathComponent)；iCloud 文件可能需要先下载")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                var last = Date.distantPast
                try OfflineModelFiles.install(from: readable, to: directory.appendingPathComponent(path), expectedHash: entry.sha256,
                    cancelled: { Task.isCancelled }, report: { copied in
                        if Date().timeIntervalSince(last) >= 0.25 {
                            last = Date(); report("导入并校验 \(path)：\(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file))")
                        }
                    })
            } catch { copyError = error }
        }
        if let error = coordinationError ?? (copyError as NSError?) { throw error }
        try await prepare(download: false, report: report)
    }

    struct Result: Sendable { let data: Data; let load: Double; let generate: Double; let audio: Double; let memory: String }
    func test(reference: String, text: String, cancellation: LabCancellation, keepModel: Bool = true,
              report: @escaping @Sendable (String) -> Void) async throws -> Result {
        guard ["gentle", "coaxing"].contains(reference) else { throw labError("无效音色") }
        // Actor methods can reenter during asynchronous model loading. Explicitly
        // serialize the lab and every reader session, including rapid voice switches.
        while generating {
            guard !cancellation.cancelled else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard !cancellation.cancelled else { throw CancellationError() }
        generating = true
        defer {
            generating = false
            if releaseRequested || !keepModel { model = nil; GPU.clearCache(); releaseRequested = false }
        }
        if !verified { try await prepare(download: false, report: report); verified = true }
        guard ProcessInfo.processInfo.physicalMemory >= 6_000_000_000 else { throw labError("实验模型至少需要 6 GB 设备内存，请继续使用 API 或系统语音") }
        let start = Date()
        let cancelled = { cancellation.cancelled || Date().timeIntervalSince(start) > 120 }
        guard !cancelled() else { throw CancellationError() }
        GPU.set(cacheLimit: 8 * 1024 * 1024)
        if model == nil { GPU.clearCache() }
        report(model == nil ? "检查分词器并加载模型（首次较慢）" : "复用已加载模型")
        if model == nil { model = try await Qwen3TTSModel.fromPretrained(directory.path, shouldCancel: cancelled) }
        guard !cancelled(), let model else { throw CancellationError() }
        let load = Date().timeIntervalSince(start)
        let before = GPU.activeMemory
        let footprintBefore = localSpeechFootprint()
        // Keep MLX arrays and Objective-C temporary objects inside this scope.
        // Cache clearing happens only after arrays/audio have been released.
        let generatedAt = Date()
        let rendered: (Data, Double) = try autoreleasepool {
        let (rate, referenceAudio) = try loadAudioArray(from: Bundle.main.bundleURL.appendingPathComponent("VoiceReferences/\(reference).wav"))
        guard rate == 24_000 else { throw labError("参考录音采样率不匹配") }
        report("生成语音：0 帧")
        var frames = 0
        let audio = try model.generateVoiceClone(text: text, referenceAudio: referenceAudio,
            referenceText: "你回来啦，今天辛苦了。要不要坐下来，让我陪你读一会儿书？别着急，今晚的故事，我们慢慢听。",
            language: "chinese", temperature: 0.7, maxTokens: 384,
            onToken: { _ in frames += 1; if frames % 8 == 0 { report("生成语音：\(frames) 帧（不是下载进度）") } },
            shouldCancel: cancelled)
        guard !cancelled() else { throw CancellationError() }
        guard frames < 384 else { throw labError("达到生成上限，未播放可能截断的音频；请重试或切换系统语音") }
        let samples = audio.asArray(Float.self)
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw labError("模型返回无效音频") }
        let data = try SpeechWAV.encode(samples: samples)
        return (data, Double(samples.count) / 24_000)
        }
        GPU.clearCache()
        let memory = String(format: "MLX 活跃内存 %.0f → %.0f MB · MLX 历史峰值 %.0f MB", Double(before) / 1_048_576, Double(GPU.activeMemory) / 1_048_576, Double(GPU.peakMemory) / 1_048_576) + " · " + footprintBefore + " → " + localSpeechFootprint()
        report(memory)
        return Result(data: rendered.0, load: load, generate: Date().timeIntervalSince(generatedAt), audio: rendered.1, memory: memory)
    }
    func release() {
        if generating { releaseRequested = true }
        else { model = nil; GPU.clearCache() }
    }
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
    @Published var seriesLog = ""
    private var task: Task<Void, Never>?
    private var cancellation = LabCancellation()
    private var player: AVAudioPlayer?

    func prepare(source: String, custom: String) { begin(label: hasBundledLabModel ? "内置模型校验" : "下载/校验") { report, _ in
        try await OfflineLabWorker.shared.prepare(source: source, custom: custom, report: report)
        return nil
    } }
    func importFile(_ url: URL, path: String) { begin(label: "导入/校验") { report, _ in
        try await OfflineLabWorker.shared.importFile(url, path: path, report: report)
        return nil
    } }
    func test(reference: String, text: String) {
        guard ready else { status = hasBundledLabModel ? "请先校验内置模型，无需下载" : "请先下载并校验模型"; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 40 else { status = "请输入 1–40 字测试句"; return }
        guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { status = "设备温度较高，请降温后再试"; return }
        begin(label: "语音测试") { report, token in try await OfflineLabWorker.shared.test(reference: reference, text: text, cancellation: token, report: report) }
    }
    func testSeries(reference: String) {
        guard ready else { status = "请先校验内置模型"; return }
        begin(label: "语音测试") { report, token in
            let sentences = ["早晨的阳光照进书房，桌上放着一本还没读完的书。", "窗外很安静，偶尔能听见微风吹过树叶的声音。", "她翻开下一页，把刚才想到的问题记在纸上。", "不必急着读完，理解每一段的意思同样重要。"]
            var latest: OfflineLabWorker.Result?
            var lines: [String] = []
            for index in 0..<20 {
                try Task.checkCancellation()
                guard !token.cancelled else { throw CancellationError() }
                guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { throw labError("连续测试因设备高温停止，请降温后重试") }
                let output = try await OfflineLabWorker.shared.test(reference: reference, text: sentences[index % sentences.count], cancellation: token, keepModel: false) { message in report("连续测试 \(index + 1)/20 · 稳定模式 · \(message)") }
                latest = output
                lines.append(String(format: "%02d · 生成 %.1fs / 音频 %.1fs · ", index + 1, output.generate, output.audio) + output.memory)
                let snapshot = lines.joined(separator: "\n")
                await MainActor.run { if !token.cancelled { OfflineLabState.shared.seriesLog = snapshot } }
            }
            return latest
        }
    }
    private func begin(label: String, _ operation: @escaping @Sendable (@escaping @Sendable (String) -> Void, LabCancellation) async throws -> OfflineLabWorker.Result?) {
        guard !busy else { return }
        player?.stop(); player = nil; busy = true; result = ""; seriesLog = ""; startedAt = Date()
        status = "正在准备\(label)…"
        if label != "语音测试" { ready = false }
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
                    result += "\n" + output.memory
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    player = try AVAudioPlayer(data: output.data)
                    guard player?.play() == true else { throw labError("音频播放失败") }
                    status = "生成完成，正在试听；可切换音色重测"
                } else { ready = true; status = "模型完整性校验通过，可断网测试 1 号 / 4 号" }
            } catch {
                await OfflineLabWorker.shared.release()
                status = token.cancelled || Task.isCancelled ? "已取消并释放模型；已完成文件会保留" : "\(label)未完成：\(error.localizedDescription)"
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
    @AppStorage("offlineLabSource") private var source = "official"
    @AppStorage("offlineLabCustomRoot") private var custom = ""
    @State private var importsModel = false
    @State private var importPath = "model.safetensors"
    var body: some View {
        NavigationStack {
            Form {
                Section("独立实验，不接管阅读器") {
                    if hasBundledLabModel {
                        Text("模型与 1号/4号音色已完整内置，无需下载。TXT 正文的智能语音中也可选择本地音色；仅主动朗读时加载。短句已获真机反馈，长时间朗读、发热与内存仍待验收。")
                        Button("校验内置模型（无需联网）") { state.prepare(source: "official", custom: "") }.disabled(state.busy)
                    } else {
                        Text("模型约 1.7 GB，可用 Wi-Fi 或蜂窝网络下载，也可从文件导入。建议预留 4 GB 空间，保持页面在前台。校验后可断网试听；不上传正文，尚未通过真机性能验收。")
                    }
                }
                if !hasBundledLabModel {
                Section("下载源") {
                    Picker("来源", selection: $source) {
                        Text("Hugging Face 官方").tag("official")
                        Text("HF Mirror 备用（第三方）").tag("mirror")
                        Text("自定义 HTTPS 根目录").tag("custom")
                    }.disabled(state.busy)
                    if source == "custom" {
                        TextField("https://你的域名/模型目录", text: $custom).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(state.busy)
                        Text("目录下需有 model.safetensors 和 speech_tokenizer/model.safetensors；此处不是语音 API 地址。不要填写密钥。")
                    }
                    if source == "mirror" { Text("第三方镜像可见下载请求与 IP；仅下载模型，不发送正文。可用性因网络而异，所有文件仍按原版 SHA256 校验。") }
                    Button("从所选来源下载 / 补齐模型") { state.prepare(source: source, custom: custom) }.disabled(state.busy)
                }
                Section("从“文件”导入（不需要连接下载源）") {
                    Text("选择解压后的两个权重文件；它们同名但位于不同目录。配置和分词器由软件自动补齐。暂不支持 ZIP。")
                    Button("导入主模型（约 1.02 GB）") { importPath = "model.safetensors"; importsModel = true }.disabled(state.busy)
                    Button("导入语音解码器（约 682 MB）") { importPath = "speech_tokenizer/model.safetensors"; importsModel = true }.disabled(state.busy)
                    if let url = try? OfflineModelFiles.sourceURL(path: "model.safetensors", source: source, custom: custom) { Link("在浏览器打开主模型下载", destination: url) }
                    if let url = try? OfflineModelFiles.sourceURL(path: "speech_tokenizer/model.safetensors", source: source, custom: custom) { Link("在浏览器打开解码器下载", destination: url) }
                }
                }
                Section("短句测试") {
                    Picker("参考音色", selection: $reference) {
                        Text("温柔自然 · 1号").tag("gentle")
                        Text("温柔微嗲 · 4号").tag("coaxing")
                    }.disabled(state.busy)
                    TextField("1–40 字", text: $text, axis: .vertical).disabled(state.busy)
                    Button("在本机生成并试听") { state.test(reference: reference, text: text) }.disabled(state.busy || !state.ready)
                    Button("连续生成 20 段并记录内存") { state.testSeries(reference: reference) }.disabled(state.busy || !state.ready)
                    Text("连续测试不读磁盘音频缓存，每段真实推理；结束后试听最后一段。保持前台，可随时取消。分别记录 MLX 内存和 App 内存；历史峰值仅指 MLX。")
                        .font(.caption)
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
                    if !state.seriesLog.isEmpty { Text(state.seriesLog).font(.caption).textSelection(.enabled) }
                }
            }
            .navigationTitle("离线语音实验室")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { state.stop(); dismiss() } } }
        }
        .onDisappear { state.stop() }
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url): state.importFile(url, path: importPath)
            case .failure(let error): state.status = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { state.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in state.stop() }
    }
}
#endif
