import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var theme: ThemeStore
    @StateObject private var model: ReaderViewModel
    private let bookID: String?
    private let onProgress: (Double) -> Void

    init(book: Book? = nil, paragraphs: [String]? = nil, onProgress: @escaping (Double) -> Void = { _ in }) {
        let id = book?.id
        self.bookID = id
        self.onProgress = onProgress
        let start = id.map { UserDefaults.standard.integer(forKey: "text.\($0)") } ?? 0
        _model = StateObject(wrappedValue: ReaderViewModel(title: book?.title ?? "为什么阅读需要一个闭环", paragraphs: paragraphs ?? ReaderViewModel.sampleParagraphs, startIndex: start))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(theme.palette.text)
                        Text("示例内容 · 自动识别中英文")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.palette.accent)
                            .padding(.bottom, 10)

                        ForEach(Array(model.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                            Text(paragraph)
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
                    .padding(24)
                }
                .onChange(of: model.currentParagraph) { _, index in
                    withAnimation { proxy.scrollTo(index, anchor: .center) }
                    if let bookID { UserDefaults.standard.set(index, forKey: "text.\(bookID)") }
                    onProgress(model.paragraphs.count <= 1 ? 0 : Double(index) / Double(model.paragraphs.count - 1))
                }
            }
            .background(theme.palette.background)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { speechControls }
        }
        .tint(theme.palette.accent)
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
                Menu {
                    Button("自动匹配段落语言") { model.chooseVoice(nil) }
                    ForEach(model.voices.prefix(50)) { voice in
                        Button("\(voice.name) · \(voice.languageTag) · \(voice.quality)") { model.chooseVoice(voice.id) }
                    }
                } label: {
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
    }

    private var selectedVoiceName: String {
        model.voices.first(where: { $0.id == model.selectedVoiceID })?.name ?? "自动音色"
    }
    private var speedDisplay: Float { 0.6 + (model.rate - 0.35) / 0.30 }
}

#Preview { ReaderView().environmentObject(ThemeStore()) }
