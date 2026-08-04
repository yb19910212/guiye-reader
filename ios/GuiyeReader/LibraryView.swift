import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var repository = BookRepository()
    @State private var importing = false
    @State private var selectedBook: Book?
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    private let paper = Color(red: 0.965, green: 0.953, blue: 0.918)
    private let moss = Color(red: 0.192, green: 0.373, blue: 0.286)
    private var epubType: UTType { UTType(filenameExtension: "epub") ?? .data }

    var body: some View {
        NavigationStack {
            Group { repository.books.isEmpty ? AnyView(emptyState) : AnyView(bookList) }
                .background(paper)
                .overlay(alignment: .top) {
                    if let progress = repository.importProgress {
                        VStack(spacing: 6) {
                            ProgressView(value: progress)
                            Text(repository.importStatus ?? "正在导入").font(.caption).lineLimit(1)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                }
                .navigationTitle("归页")
                .searchable(text: $searchText, prompt: "搜索书名或作者")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("导入") { importing = true } } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, epubType], allowsMultipleSelection: true) { result in
                    switch result { case .success(let urls): repository.importFiles(urls); case .failure(let error): repository.lastError = error.localizedDescription }
                }
                .navigationDestination(item: $selectedBook) { book in
                    if book.format == .pdf {
                        PDFReaderView(book: book) { repository.updateProgress(bookID: book.id, progress: $0) }
                    } else if book.format == .epub {
                        EPUBReaderView(book: book) { repository.updateProgress(bookID: book.id, progress: $0) }
                    } else {
                        ReaderView(book: book, paragraphs: repository.paragraphs(for: book)) { repository.updateProgress(bookID: book.id, progress: $0) }
                    }
                }
        }.tint(moss)
    }

    private var emptyState: some View {
        ContentUnavailableView { Label("还没有书", systemImage: "books.vertical") } description: { Text(repository.lastError ?? "从文件 App 导入 EPUB、PDF 或 TXT") } actions: { Button("导入第一本书") { importing = true }.buttonStyle(.borderedProminent) }
    }
    private var bookList: some View {
        List {
            if let error = repository.lastError { Text(error).foregroundStyle(.red) }
            Section("我的书库") {
                Picker("筛选", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(filteredBooks) { book in
                    Button { selectedBook = book } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 6).fill(moss).frame(width: 52, height: 70).overlay(Text(book.format.rawValue.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(book.title).font(.headline).foregroundStyle(.primary)
                                Text("\(book.format.rawValue.uppercased()) · \(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))").font(.subheadline).foregroundStyle(.secondary)
                                ProgressView(value: book.progress)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }
        }.scrollContentBackground(.hidden)
    }

    private var filteredBooks: [Book] {
        repository.books.filter { book in
            let queryMatches = searchText.isEmpty || book.title.localizedCaseInsensitiveContains(searchText) || (book.author?.localizedCaseInsensitiveContains(searchText) == true)
            let stateMatches: Bool
            switch filter {
            case .all: stateMatches = true
            case .reading: stateMatches = book.progress > 0 && book.progress < 0.98
            case .unread: stateMatches = book.progress == 0
            case .finished: stateMatches = book.progress >= 0.98
            }
            return queryMatches && stateMatches
        }
    }
}

private enum LibraryFilter: CaseIterable { case all, reading, unread, finished
    var title: String { switch self { case .all: "全部"; case .reading: "在读"; case .unread: "未读"; case .finished: "读完" } }
}

#Preview { LibraryView() }
