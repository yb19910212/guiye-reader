import SwiftUI

struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    private let paper = Color(red: 0.965, green: 0.953, blue: 0.918)
    private let ink = Color(red: 0.118, green: 0.169, blue: 0.141)
    private let moss = Color(red: 0.192, green: 0.373, blue: 0.286)

    init(book: Book? = nil, paragraphs: [String]? = nil) {
        _model = StateObject(wrappedValue: ReaderViewModel(title: book?.title ?? "为什么阅读需要一个闭环", paragraphs: paragraphs ?? ReaderViewModel.sampleParagraphs))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(ink)
                        Text("示例内容 · 自动识别中英文")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(moss)
                            .padding(.bottom, 10)

                        ForEach(Array(model.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                            Text(paragraph)
                                .font(.system(size: 20, design: .serif))
                                .lineSpacing(9)
                                .foregroundStyle(ink)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == model.currentParagraph && model.playbackState != .idle ? moss.opacity(0.12) : .clear)
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
                }
            }
            .background(paper)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { speechControls }
        }
        .tint(moss)
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

#Preview { ReaderView() }
