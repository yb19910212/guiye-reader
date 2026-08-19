import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var theme: ThemeStore
    @StateObject private var model: ReaderViewModel
    private let bookID: String?
    private let onProgress: (Double) -> Void
    private let loadParagraphs: (() async -> [String])?
    @State private var showsVoiceLibrary = false
    @State private var visibleParagraph: Int?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var isRecordingScroll = false
    @Environment(\.scenePhase) private var scenePhase

    init(book: Book? = nil, paragraphs: [String]? = nil, loadParagraphs: (() async -> [String])? = nil, onProgress: @escaping (Double) -> Void = { _ in }) {
        let id = book?.id
        self.bookID = id
        self.onProgress = onProgress
        self.loadParagraphs = loadParagraphs
        let start = id.map { UserDefaults.standard.integer(forKey: "text.\($0)") } ?? 0
        _visibleParagraph = State(initialValue: start)
        _model = StateObject(wrappedValue: ReaderViewModel(title: book?.title ?? "为什么阅读需要一个闭环", paragraphs: paragraphs ?? (loadParagraphs == nil ? ReaderViewModel.sampleParagraphs : ["正在载入正文…"]), startIndex: start))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(model.title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(theme.palette.text)
                        Text("示例内容 · 自动识别中英文")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.palette.accent)
                            .padding(.bottom, 10)

                        ForEach(model.paragraphs.indices, id: \.self) { index in
                            Text(model.paragraphs[index])
                                .font(.system(size: 20, design: .serif))
                                .lineSpacing(9)
                                .foregroundStyle(theme.palette.text)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == model.currentParagraph && model.playbackState != .idle ? theme.palette.highlight : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .onTapGesture { model.move(to: index) }
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(24)
                }
                .scrollPosition(id: $visibleParagraph, anchor: .top)
                .onChange(of: visibleParagraph) { _, index in
                    guard let index, model.paragraphs.indices.contains(index) else { return }
                    isRecordingScroll = true
                    model.recordReadingPosition(index)
                    Task { @MainActor in
                        await Task.yield()
                        isRecordingScroll = false
                    }
                }
                .onChange(of: model.currentParagraph) { _, index in
                    if !isRecordingScroll { withAnimation { proxy.scrollTo(index, anchor: .center) } }
                    schedulePositionSave(index)
                }
                .task(id: bookID) {
                    if let loadParagraphs {
                        model.replaceParagraphs(await loadParagraphs())
                        visibleParagraph = model.currentParagraph
                        proxy.scrollTo(model.currentParagraph, anchor: .top)
                    }
                }
            }
            .background(theme.palette.background)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { speechControls }
        }
        .tint(theme.palette.accent)
        .onDisappear { persistPositionImmediately() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { persistPositionImmediately() }
        }
    }

    private var speechControls: some View {
        VStack(spacing: 8) {
            HStack {
                Button("上一段", action: model.previous)
                Spacer()
                Button(action: model.playOrPause) {
                    Label(model.playbackState == .playing ? "暂停朗读" : "开始朗读", systemImage: model.playbackState == .playing ? "pause.fill" : "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("下一段", action: model.next)
            }
            HStack {
                Button { showsVoiceLibrary = true } label: {
                    Label(selectedVoiceName, systemImage: "waveform")
                        .lineLimit(1)
                }
                Spacer()
                Text(String(format: "%.1f×", speedDisplay))
                    .monospacedDigit()
                Slider(value: Binding(get: { model.rate }, set: model.updateRate), in: 0.35...0.65)
                    .frame(maxWidth: 150)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showsVoiceLibrary) { VoiceLibraryView(model: model) }
    }

    private var selectedVoiceName: String {
        model.voices.first(where: { $0.id == model.selectedVoiceID })?.name ?? "自动音色"
    }
    private var speedDisplay: Float { 0.6 + (model.rate - 0.35) / 0.30 }

    private func schedulePositionSave(_ index: Int) {
        guard let bookID else { return }
        UserDefaults.standard.set(index, forKey: "text.\(bookID)")
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            onProgress(progress(for: index))
        }
    }

    private func persistPositionImmediately() {
        guard let bookID else { return }
        progressSaveTask?.cancel()
        let index = model.currentParagraph
        UserDefaults.standard.set(index, forKey: "text.\(bookID)")
        onProgress(progress(for: index))
    }

    private func progress(for index: Int) -> Double {
        model.paragraphs.count <= 1 ? 0 : Double(index) / Double(model.paragraphs.count - 1)
    }
}

private struct VoiceLibraryView: View {
    @ObservedObject var model: ReaderViewModel
    @State private var query = ""
    @State private var highQualityOnly = true
    @Environment(\.dismiss) private var dismiss

    private var voices: [SpeechVoice] {
        model.voices.filter { voice in
            (!highQualityOnly || voice.qualityRank >= 2)
                && (query.isEmpty || voice.name.localizedCaseInsensitiveContains(query) || voice.languageName.localizedCaseInsensitiveContains(query) || voice.languageTag.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.chooseVoice(nil)
                        dismiss()
                    } label: {
                        Label("自动匹配每段语言", systemImage: model.selectedVoiceID == nil ? "checkmark.circle.fill" : "wand.and.stars")
                    }
                    Toggle("优先显示 Premium / 增强音色", isOn: $highQualityOnly)
                    Text("更多高级音色：打开系统“设置 › 辅助功能 › 朗读内容 › 声音”下载。Siri 专属音色不向第三方 App 开放。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if voices.isEmpty {
                    ContentUnavailableView("没有匹配的高级音色", systemImage: "waveform", description: Text("关闭上方筛选可查看设备全部音色"))
                } else {
                    ForEach(languageGroups) { group in
                        Section(group.key) {
                            ForEach(group.value) { voice in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(voice.name).font(.headline)
                                        Text("\(voice.languageName) · \(voice.quality)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedVoiceID == voice.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                    Button("试听") { model.previewVoice(voice) }.buttonStyle(.bordered)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.chooseVoice(voice.id) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索音色或语言")
            .navigationTitle("智能语音")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var languageGroups: [VoiceGroup] {
        let grouped = Dictionary(grouping: voices) { voice -> String in
            if voice.languageTag.hasPrefix("zh-CN") { return "普通话" }
            if voice.languageTag.hasPrefix("zh-HK") || voice.languageTag.hasPrefix("yue") { return "粤语" }
            if voice.languageTag.hasPrefix("zh-TW") { return "台语 / 繁体中文" }
            if voice.languageTag.hasPrefix("en") { return "英语" }
            if voice.languageTag.hasPrefix("ja") { return "日语" }
            if voice.languageTag.hasPrefix("ko") { return "韩语" }
            return "其他语言"
        }
        let order = ["普通话", "粤语", "台语 / 繁体中文", "英语", "日语", "韩语", "其他语言"]
        return order.compactMap { key in grouped[key].map { VoiceGroup(key: key, value: $0) } }
    }
}

private struct VoiceGroup: Identifiable {
    let key: String
    let value: [SpeechVoice]
    var id: String { key }
}

#Preview { ReaderView().environmentObject(ThemeStore()) }

