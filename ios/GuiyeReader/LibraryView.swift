import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var theme: ThemeStore
    @StateObject private var repository = BookRepository()
    @State private var importing = false
    @State private var selectedBook: Book?
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var showsNotes = false
    @State private var showsAISettings = false
    @State private var showsOPDS = false
    @State private var showsRemoteLibrary = false
    @State private var showsThemes = false
    @State private var exportsBackup = false
    @State private var pendingImportURLs: [URL] = []
    @State private var showsHistory = false
    @State private var editingBook: Book?
    @State private var selectedBookIDs: Set<String> = []
    @State private var editMode: EditMode = .inactive
    private var epubType: UTType { UTType(filenameExtension: "epub") ?? .data }
    private var txtType: UTType { UTType(filenameExtension: "txt") ?? .plainText }

    var body: some View {
        NavigationStack {
            Group { repository.books.isEmpty ? AnyView(emptyState) : AnyView(bookList) }
                .background(theme.palette.background)
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
                .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { exportsBackup = true } label: { Label("备份", systemImage: "externaldrive") }
                    Button { showsAISettings = true } label: { Label("AI", systemImage: "sparkles") }
                    Button { showsThemes = true } label: { Label("主题", systemImage: "paintpalette") }
                    Menu {
                        Button { importing = true } label: { Label("本机 / iCloud / SMB", systemImage: "folder") }
                        Button { showsRemoteLibrary = true } label: { Label("WebDAV / SMB 文件夹", systemImage: "externaldrive.connected.to.line.below") }
                        Button { showsOPDS = true } label: { Label("OPDS 书库", systemImage: "books.vertical") }
                    } label: { Label("网络", systemImage: "network") }
                    Button { showsNotes = true } label: { Label("笔记", systemImage: "note.text") }
                    Button { showsHistory = true } label: { Label("历史", systemImage: "clock.arrow.circlepath") }
                    Button(editMode.isEditing ? "完成" : "管理") {
                        editMode = editMode.isEditing ? .inactive : .active
                        if !editMode.isEditing { selectedBookIDs.removeAll() }
                    }
                    Button("导入") { importing = true }
                } }
                .navigationDestination(item: $selectedBook) { book in
                    if book.format == .pdf {
                        PDFReaderView(book: book) { repository.updateProgress(bookID: book.id, progress: $0) }
                    } else if book.format == .epub {
                        EPUBReaderView(book: book) { repository.updateProgress(bookID: book.id, progress: $0) }
                    } else {
                        ReaderView(book: book, loadParagraphs: { await repository.paragraphs(for: book) }) { repository.updateProgress(bookID: book.id, progress: $0) }
                    }
                }
                .sheet(isPresented: $showsNotes) { NotesView(books: repository.books) }
                .sheet(isPresented: $showsAISettings) { AISettingsView() }
                .sheet(isPresented: $showsThemes) { ThemeSettingsView().environmentObject(theme) }
                .sheet(isPresented: $showsOPDS) { OPDSCatalogView(repository: repository) }
                .sheet(isPresented: $showsRemoteLibrary) { RemoteLibraryView(repository: repository) }
                .sheet(isPresented: $showsHistory) {
                    ReadingHistoryView(books: repository.books) { book in
                        showsHistory = false
                        openBook(book)
                    }
                }
                .sheet(item: $editingBook) { book in
                    BookEditorView(book: book) { title, author in repository.updateMetadata(bookID: book.id, title: title, author: author) }
                }
                .fileExporter(isPresented: $exportsBackup, document: LibraryBackupDocument(data: repository.backupData()), contentType: .json, defaultFilename: "GuiyeReader-Backup") { result in
                    if case .failure(let error) = result { repository.lastError = error.localizedDescription }
                }
        }
        .tint(theme.palette.accent)
        .environment(\.editMode, $editMode)
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                HStack {
                    Text("已选择 \(selectedBookIDs.count) 本")
                    Spacer()
                    Button("删除", role: .destructive) {
                        repository.deleteBooks(ids: selectedBookIDs)
                        selectedBookIDs.removeAll(); editMode = .inactive
                    }.disabled(selectedBookIDs.isEmpty)
                }.padding().background(.bar)
            }
        }
        .sheet(isPresented: $importing) {
            DocumentPicker(contentTypes: [txtType, .plainText, .text, .pdf, epubType], onPicked: { urls in
                pendingImportURLs = urls
                importing = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    let queued = pendingImportURLs
                    pendingImportURLs = []
                    repository.importFiles(queued)
                }
            }, onFailure: { error in
                importing = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    repository.lastError = error.localizedDescription
                    repository.importNotice = error.localizedDescription
                }
            })
        }
        .alert("导入结果", isPresented: Binding(get: { repository.importNotice != nil }, set: { if !$0 { repository.importNotice = nil } })) {
            Button("知道了") { repository.importNotice = nil }
        } message: { Text(repository.importNotice ?? "") }
    }

    private var emptyState: some View {
        ContentUnavailableView { Label("还没有书", systemImage: "books.vertical") } description: { Text(repository.lastError ?? "从文件 App 导入 EPUB、PDF 或 TXT") } actions: { Button("导入第一本书") { importing = true }.buttonStyle(.borderedProminent) }
    }
    private var bookList: some View {
        List(selection: $selectedBookIDs) {
            if let error = repository.lastError { Text(error).foregroundStyle(.red) }
            Section("我的书库") {
                Picker("筛选", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(filteredBooks) { book in
                    Group {
                        if editMode.isEditing { bookRow(book) }
                        else { Button { openBook(book) } label: { bookRow(book) } }
                    }
                    .tag(book.id)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { repository.deleteBooks(ids: [book.id]) }
                        Button("编辑") { editingBook = book }.tint(.blue)
                    }
                    .contextMenu {
                        Button("编辑书籍信息") { editingBook = book }
                        Button("删除", role: .destructive) { repository.deleteBooks(ids: [book.id]) }
                    }
                }
            }
        }.scrollContentBackground(.hidden)
    }

    private func openBook(_ book: Book) {
        repository.markOpened(bookID: book.id)
        selectedBook = repository.books.first(where: { $0.id == book.id }) ?? book
    }

    private func bookRow(_ book: Book) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 6).fill(theme.palette.accent).frame(width: 52, height: 70)
                .overlay(Text(book.format.rawValue.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.headline).foregroundStyle(.primary)
                Text([book.author, book.format.rawValue.uppercased(), ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: book.progress)
            }
        }.padding(.vertical, 5)
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

#Preview { LibraryView().environmentObject(ThemeStore()) }
