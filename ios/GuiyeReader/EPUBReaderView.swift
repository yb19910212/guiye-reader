import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit

@MainActor
private final class EPUBReadiumService {
    static let shared = EPUBReadiumService()
    private let httpClient = DefaultHTTPClient()
    private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    private lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )

    func open(_ url: URL) async throws -> Publication {
        let asset = try await assetRetriever.retrieve(url: FileURL(url: url)!).get()
        return try await publicationOpener.open(asset: asset, allowUserInteraction: false, sender: nil).get()
    }
}

@MainActor
private final class EPUBReaderBridge: ObservableObject {
    @Published var navigator: EPUBNavigatorViewController?
    @Published var tableOfContents: [ReadiumShared.Link] = []
    @Published var error: String?
}

struct EPUBReaderView: View {
    let book: Book
    let onProgress: (Double) -> Void
    @StateObject private var bridge = EPUBReaderBridge()
    @State private var showsContents = false
    @State private var showsAppearance = false
    @AppStorage("reader.fontSize") private var fontSize = 1.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.5
    @AppStorage("reader.pageMargins") private var pageMargins = 1.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 0.5
    @AppStorage("reader.scroll") private var scroll = false
    @AppStorage("reader.theme") private var theme = "light"

    init(book: Book, onProgress: @escaping (Double) -> Void = { _ in }) {
        self.book = book
        self.onProgress = onProgress
    }

    var body: some View {
        EPUBNavigatorContainer(book: book, bridge: bridge, preferences: preferences, onProgress: onProgress)
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { showsAppearance = true } label: { Text("Aa") }
                        Button { showsContents = true } label: { Label("目录", systemImage: "list.bullet") }
                            .disabled(bridge.tableOfContents.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showsContents) {
                NavigationStack {
                    List(flatten(bridge.tableOfContents), id: \.href) { item in
                        Button(item.title ?? "未命名章节") {
                            showsContents = false
                            Task { await bridge.navigator?.go(to: item) }
                        }
                    }
                    .navigationTitle("目录")
                }
            }
            .sheet(isPresented: $showsAppearance) {
                NavigationStack {
                    Form {
                        Section("文字") {
                            LabeledContent("字号") { Slider(value: $fontSize, in: 0.7...2.0, step: 0.05).frame(width: 190) }
                            LabeledContent("行距") { Slider(value: $lineHeight, in: 1.0...2.2, step: 0.1).frame(width: 190) }
                            LabeledContent("页边距") { Slider(value: $pageMargins, in: 0.5...2.0, step: 0.1).frame(width: 190) }
                            LabeledContent("段落间距") { Slider(value: $paragraphSpacing, in: 0...1.5, step: 0.1).frame(width: 190) }
                        }
                        Section("阅读方式") {
                            Toggle("上下滚动", isOn: $scroll)
                            Picker("主题", selection: $theme) {
                                Text("日间").tag("light")
                                Text("纸张").tag("sepia")
                                Text("夜间").tag("dark")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .navigationTitle("阅读设置")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsAppearance = false } } }
                }
            }
            .overlay {
                if bridge.navigator == nil && bridge.error == nil { ProgressView("正在打开 EPUB…") }
                if let error = bridge.error { ContentUnavailableView("无法打开 EPUB", systemImage: "exclamationmark.triangle", description: Text(error)) }
            }
    }

    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] {
        links.flatMap { [$0] + flatten($0.children) }
    }

    private var preferences: EPUBPreferences {
        EPUBPreferences(
            fontSize: fontSize,
            lineHeight: lineHeight,
            pageMargins: pageMargins,
            paragraphSpacing: paragraphSpacing,
            publisherStyles: false,
            scroll: scroll,
            theme: theme == "dark" ? .dark : (theme == "sepia" ? .sepia : .light)
        )
    }
}

private struct EPUBNavigatorContainer: UIViewControllerRepresentable {
    let book: Book
    @ObservedObject var bridge: EPUBReaderBridge
    let preferences: EPUBPreferences
    let onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(book: book, bridge: bridge, onProgress: onProgress) }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = HighlightHostViewController()
        context.coordinator.preferences = preferences
        context.coordinator.open(in: host)
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.preferences = preferences
        bridge.navigator?.submitPreferences(preferences)
    }

    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        let book: Book
        let bridge: EPUBReaderBridge
        let onProgress: (Double) -> Void
        var preferences: EPUBPreferences = .empty

        init(book: Book, bridge: EPUBReaderBridge, onProgress: @escaping (Double) -> Void) {
            self.book = book
            self.bridge = bridge
            self.onProgress = onProgress
        }

        func open(in host: UIViewController) {
            Task { @MainActor in
                do {
                    let publication = try await EPUBReadiumService.shared.open(book.localURL)
                    let saved = UserDefaults.standard.string(forKey: "epub.\(book.id)")
                    let locator = try saved.flatMap { try Locator(json: JSONValue(jsonString: $0), warnings: nil) }
                    let navigator = try EPUBNavigatorViewController(
                        publication: publication,
                        initialLocation: locator,
                        config: .init(
                            preferences: preferences,
                            editingActions: EditingAction.defaultActions + [EditingAction(title: "高亮", action: #selector(HighlightHostViewController.saveHighlight))]
                        )
                    )
                    let highlightHost = host as? HighlightHostViewController
                    highlightHost?.navigator = navigator
                    highlightHost?.onSaveHighlight = { [book] selection in
                        guard let json = try? selection.locator.jsonString() else { return }
                        NoteStore().addHighlight(book: book, quote: selection.locator.text.highlight ?? "摘录", locator: json)
                        navigator.reloadHighlights(for: book)
                    }
                    navigator.delegate = self
                    host.addChild(navigator)
                    navigator.view.frame = host.view.bounds
                    navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    host.view.addSubview(navigator.view)
                    navigator.didMove(toParent: host)
                    bridge.navigator = navigator
                    bridge.tableOfContents = try await publication.tableOfContents().get()
                    navigator.reloadHighlights(for: book)
                } catch {
                    bridge.error = error.localizedDescription
                }
            }
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            UserDefaults.standard.set(try? locator.jsonString(), forKey: "epub.\(book.id)")
            onProgress(locator.locations.totalProgression ?? 0)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
            bridge.error = String(describing: error)
        }
    }
}

@MainActor
private final class HighlightHostViewController: UIViewController {
    weak var navigator: EPUBNavigatorViewController?
    var onSaveHighlight: ((Selection) -> Void)?

    @objc func saveHighlight() {
        guard let navigator, let selection = navigator.currentSelection else { return }
        onSaveHighlight?(selection)
        navigator.clearSelection()
    }
}

@MainActor
private extension EPUBNavigatorViewController {
    func reloadHighlights(for book: Book) {
        let decorations = NoteStore().notes.filter { $0.bookID == book.id && $0.quote != nil }.compactMap { note -> Decoration? in
            guard let value = note.locator,
                  let json = try? JSONValue(jsonString: value),
                  let locator = try? Locator(json: json, warnings: nil) else { return nil }
            return Decoration(id: note.id.uuidString, locator: locator, style: .highlight(tint: .systemYellow))
        }
        apply(decorations: decorations, in: "highlights")
    }
}
