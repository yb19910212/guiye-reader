import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var theme: ThemeStore
    @StateObject private var model: ReaderViewModel
    @StateObject private var noteStore = NoteStore()
    @StateObject private var bookmarkStore = BookmarkStore()
    private let book: Book?
    private let bookID: String?
    private let onProgress: (Double) -> Void
    private let loadParagraphs: (() async -> [String])?
    @State private var showsVoiceLibrary = false
    @State private var showsContents = false
    @State private var showsSearch = false
    @State private var showsAppearance = false
    @State private var showsAnnotation = false
    @State private var annotationDraft = ""
    @State private var visibleParagraph: Int?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var isRecordingScroll = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("textReader.fontSize") private var fontSize = 20.0
    @AppStorage("textReader.lineSpacing") private var lineSpacing = 9.0
    @AppStorage("textReader.paragraphSpacing") private var paragraphSpacing = 12.0
    @AppStorage("textReader.horizontalPadding") private var horizontalPadding = 24.0

    init(book: Book? = nil, paragraphs: [String]? = nil, loadParagraphs: (() async -> [String])? = nil, onProgress: @escaping (Double) -> Void = { _ in }) {
        let id = book?.id
        self.book = book
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
                    LazyVStack(alignment: .leading, spacing: paragraphSpacing) {
                        Text(model.title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(theme.palette.text)
                        Text("TXT · 本地阅读")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.palette.accent)
                            .padding(.bottom, 10)

                        ForEach(model.paragraphs.indices, id: \.self) { index in
                            Text(model.paragraphs[index])
                                .font(.system(size: fontSize, design: .serif))
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(theme.palette.text)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(paragraphBackground(index))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .onTapGesture { model.move(to: index) }
                                .onLongPressGesture {
                                    guard book != nil else { return }
                                    model.move(to: index)
                                    annotationDraft = ""
                                    showsAnnotation = true
                                }
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 24)
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { toggleCurrentBookmark() } label: { Image(systemName: isCurrentBookmarked ? "bookmark.fill" : "bookmark") }
                        .disabled(book == nil)
                    Button { annotationDraft = ""; showsAnnotation = true } label: { Image(systemName: "note.text.badge.plus") }
                        .disabled(book == nil)
                    Button { showsSearch = true } label: { Image(systemName: "magnifyingglass") }
                    Button { showsContents = true } label: { Image(systemName: "list.bullet") }
                    Button("Aa") { showsAppearance = true }.font(.headline)
                }
            }
            .safeAreaInset(edge: .bottom) { speechControls }
        }
        .tint(theme.palette.accent)
        .sheet(isPresented: $showsContents) { TXTContentsView(chapters: model.chapters, bookmarks: currentBookmarks, selected: jumpToParagraph) }
        .sheet(isPresented: $showsSearch) { TXTSearchView(model: model, selected: jumpToParagraph) }
        .sheet(isPresented: $showsAppearance) {
            TXTAppearanceView(fontSize: $fontSize, lineSpacing: $lineSpacing, paragraphSpacing: $paragraphSpacing, horizontalPadding: $horizontalPadding)
        }
        .sheet(isPresented: $showsAnnotation) {
            TXTAnnotationView(quote: currentParagraphText, draft: $annotationDraft) {
                guard let book else { return }
                noteStore.addAnnotation(book: book, text: annotationDraft, quote: currentParagraphText, locator: "第 \(model.currentParagraph + 1) 段")
            }
        }
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
    private var currentParagraphText: String { model.paragraphs.indices.contains(model.currentParagraph) ? model.paragraphs[model.currentParagraph] : "" }
    private var currentBookmarks: [ReadingBookmark] { book.map { bookmarkStore.forBook($0.id) } ?? [] }
    private var isCurrentBookmarked: Bool { book.map { bookmarkStore.isBookmarked(bookID: $0.id, paragraphIndex: model.currentParagraph) } ?? false }

    private func toggleCurrentBookmark() {
        guard let book else { return }
        bookmarkStore.toggle(book: book, paragraphIndex: model.currentParagraph, excerpt: currentParagraphText)
    }

    private func paragraphBackground(_ index: Int) -> Color {
        if index == model.currentParagraph && model.playbackState != .idle { return theme.palette.highlight }
        if let book, bookmarkStore.isBookmarked(bookID: book.id, paragraphIndex: index) { return theme.palette.accent.opacity(0.12) }
        return .clear
    }

    private func jumpToParagraph(_ index: Int) {
        visibleParagraph = index
        model.move(to: index)
    }

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

private struct TXTContentsView: View {
    let chapters: [TXTChapter]
    let bookmarks: [ReadingBookmark]
    let selected: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("章节") {
                    ForEach(chapters) { chapter in
                        Button {
                            selected(chapter.index)
                            dismiss()
                        } label: {
                            HStack {
                                Text(chapter.title).foregroundStyle(.primary)
                                Spacer()
                                Text("第 \(chapter.index + 1) 段").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !bookmarks.isEmpty {
                    Section("书签") {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                selected(bookmark.paragraphIndex)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bookmark.excerpt).lineLimit(2).foregroundStyle(.primary)
                                    Text("第 \(bookmark.paragraphIndex + 1) 段").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("章节目录")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct TXTAnnotationView: View {
    let quote: String
    @Binding var draft: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("原文") { Text(quote).font(.callout).foregroundStyle(.secondary).lineLimit(6) }
                Section("批注") { TextEditor(text: $draft).frame(minHeight: 180) }
            }
            .navigationTitle("段落批注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}

private struct TXTSearchView: View {
    @ObservedObject var model: ReaderViewModel
    let selected: (Int) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("搜索正文", systemImage: "text.magnifyingglass", description: Text("输入关键词，在本书中查找内容"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            selected(result.index)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.text).lineLimit(3).foregroundStyle(.primary)
                                Text("第 \(result.index + 1) 段").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索本书正文")
            .navigationTitle("正文搜索")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var results: [TXTSearchResult] { model.search(query) }
}

private struct TXTAppearanceView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var paragraphSpacing: Double
    @Binding var horizontalPadding: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("正文") {
                    setting("字号", value: $fontSize, range: 14...34, suffix: " pt")
                    setting("行距", value: $lineSpacing, range: 2...20, suffix: "")
                    setting("段距", value: $paragraphSpacing, range: 4...28, suffix: "")
                    setting("页边距", value: $horizontalPadding, range: 12...48, suffix: "")
                }
                Section {
                    Button("恢复默认排版") {
                        fontSize = 20; lineSpacing = 9; paragraphSpacing = 12; horizontalPadding = 24
                    }
                }
            }
            .navigationTitle("阅读排版")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func setting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))\(suffix)").foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range, step: 1)
        }
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

