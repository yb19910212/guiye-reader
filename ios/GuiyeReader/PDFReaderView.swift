import PDFKit
import SwiftUI

struct PDFReaderView: View {
    let book: Book
    let onProgress: (Double) -> Void
    @State private var pageIndex: Int
    @State private var pageCount = 1

    init(book: Book, onProgress: @escaping (Double) -> Void = { _ in }) {
        self.book = book
        self.onProgress = onProgress
        _pageIndex = State(initialValue: UserDefaults.standard.integer(forKey: "pdf.\(book.id)"))
    }

    var body: some View {
        VStack(spacing: 0) {
            PDFKitView(url: book.localURL, pageIndex: $pageIndex, pageCount: $pageCount)
            HStack {
                Button("上一页") { pageIndex = max(0, pageIndex - 1) }
                    .disabled(pageIndex == 0)
                Spacer()
                Text("\(pageIndex + 1) / \(pageCount)").monospacedDigit()
                Spacer()
                Button("下一页") { pageIndex = min(pageCount - 1, pageIndex + 1) }
                    .disabled(pageIndex + 1 >= pageCount)
            }
            .padding()
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pageIndex) { _, value in
            UserDefaults.standard.set(value, forKey: "pdf.\(book.id)")
            onProgress(pageCount <= 1 ? 0 : Double(value) / Double(pageCount - 1))
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var pageCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = PDFDocument(url: url)
        pageCount = max(1, view.document?.pageCount ?? 1)
        context.coordinator.view = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        go(to: pageIndex, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        go(to: pageIndex, in: view)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    private func go(to index: Int, in view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let safeIndex = min(max(index, 0), document.pageCount - 1)
        guard let page = document.page(at: safeIndex) else { return }
        if view.currentPage !== page { view.go(to: page) }
    }

    final class Coordinator: NSObject {
        var parent: PDFKitView
        weak var view: PDFView?

        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged() {
            guard let view, let document = view.document, let page = view.currentPage else { return }
            parent.pageIndex = document.index(for: page)
        }
    }
}
