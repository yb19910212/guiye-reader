import SwiftUI

struct NotesView: View {
    let books: [Book]
    @StateObject private var store = NoteStore()
    @State private var searchText = ""
    @State private var showsEditor = false
    @State private var selectedBookID = ""
    @State private var draft = ""
    @State private var draftTags = ""
    @State private var editingNote: ReadingNote?

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredNotes) { note in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(note.bookTitle).font(.headline)
                        if let quote = note.quote { Text("“\(quote)”").font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                        Text(note.text)
                        if let locator = note.locator { Label(locator, systemImage: "location").font(.caption).foregroundStyle(.secondary) }
                        if let tags = note.tags, !tags.isEmpty { Text(tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(Color.accentColor) }
                        if note.quote != nil { Label(note.color == "annotation" ? "段落批注" : "高亮摘录", systemImage: note.color == "annotation" ? "note.text" : "highlighter").font(.caption).foregroundStyle(.orange) }
                        Text(note.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("编辑") { editingNote = note; draft = note.text; draftTags = (note.tags ?? []).joined(separator: ", ") }
                        Button("删除", role: .destructive) { store.remove(ids: [note.id]) }
                    }
                }
                .onDelete { offsets in store.remove(ids: Set(offsets.map { filteredNotes[$0].id })) }
            }
            .overlay { if store.notes.isEmpty { ContentUnavailableView("还没有笔记", systemImage: "note.text", description: Text("笔记永远属于你，并可随时导出。")) } }
            .searchable(text: $searchText, prompt: "搜索全部笔记")
            .navigationTitle("阅读笔记")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: store.markdown, subject: Text("归页阅读笔记")) { Image(systemName: "square.and.arrow.up") }
                    Button { selectedBookID = selectedBookID.isEmpty ? (books.first?.id ?? "") : selectedBookID; showsEditor = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showsEditor) {
                NavigationStack {
                    Form {
                        Picker("书籍", selection: $selectedBookID) { ForEach(books) { Text($0.title).tag($0.id) } }
                        TextEditor(text: $draft).frame(minHeight: 180)
                        TextField("标签，用逗号分隔", text: $draftTags)
                    }
                    .navigationTitle("新建笔记")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showsEditor = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") {
                            if let book = books.first(where: { $0.id == selectedBookID }) { store.add(book: book, text: draft, tags: parsedTags) }
                            draft = ""; draftTags = ""; showsEditor = false
                        } }
                    }
                }
            }
            .sheet(item: $editingNote) { note in
                NavigationStack {
                    Form {
                        TextEditor(text: $draft).frame(minHeight: 180)
                        TextField("标签，用逗号分隔", text: $draftTags)
                    }
                    .navigationTitle("编辑笔记")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editingNote = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { store.update(id: note.id, text: draft, tags: parsedTags); editingNote = nil } }
                    }
                }
            }
        }
    }

    private var filteredNotes: [ReadingNote] {
        searchText.isEmpty ? store.notes : store.notes.filter { $0.text.localizedCaseInsensitiveContains(searchText) || $0.bookTitle.localizedCaseInsensitiveContains(searchText) || ($0.quote?.localizedCaseInsensitiveContains(searchText) == true) || ($0.tags?.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) == true) }
    }

    private var parsedTags: [String] { draftTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}

