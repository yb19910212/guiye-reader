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

    init(book: Book, onProgress: @escaping (Double) -> Void = { _ in }) {
        self.book = book
        self.onProgress = onProgress
    }

    var body: some View {
        EPUBNavigatorContainer(book: book, bridge: bridge, onProgress: onProgress)
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsContents = true } label: { Label("目录", systemImage: "list.bullet") }
                        .disabled(bridge.tableOfContents.isEmpty)
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
            .overlay {
                if bridge.navigator == nil && bridge.error == nil { ProgressView("正在打开 EPUB…") }
                if let error = bridge.error { ContentUnavailableView("无法打开 EPUB", systemImage: "exclamationmark.triangle", description: Text(error)) }
            }
    }

    private func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] {
        links.flatMap { [$0] + flatten($0.children) }
    }
}

private struct EPUBNavigatorContainer: UIViewControllerRepresentable {
    let book: Book
    @ObservedObject var bridge: EPUBReaderBridge
    let onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(book: book, bridge: bridge, onProgress: onProgress) }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        context.coordinator.open(in: host)
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, NavigatorDelegate {
        let book: Book
        let bridge: EPUBReaderBridge
        let onProgress: (Double) -> Void

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
                    let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator)
                    navigator.delegate = self
                    host.addChild(navigator)
                    navigator.view.frame = host.view.bounds
                    navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    host.view.addSubview(navigator.view)
                    navigator.didMove(toParent: host)
                    bridge.navigator = navigator
                    bridge.tableOfContents = try await publication.tableOfContents().get()
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
