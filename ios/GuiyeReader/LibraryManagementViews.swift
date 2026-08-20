import SwiftUI

struct ReadingHistoryView: View {
    let books: [Book]
    let open: (Book) -> Void
    @Environment(\.dismiss) private var dismiss

    private var history: [Book] {
        books.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    ContentUnavailableView("还没有阅读历史", systemImage: "clock", description: Text("打开一本书后会自动记录阅读时间和进度"))
                } else {
                    ForEach(history) { book in
                        Button { open(book) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text(book.title).font(.headline); Spacer(); Text("\(Int(book.progress * 100))%").monospacedDigit() }
                                ProgressView(value: book.progress)
                                if let date = book.lastOpenedAt {
                                    Text("上次阅读：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5)
                        }.foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("阅读历史")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct BookEditorView: View {
    let book: Book
    let save: (String, String?) -> Void
    @State private var title: String
    @State private var author: String
    @Environment(\.dismiss) private var dismiss

    init(book: Book, save: @escaping (String, String?) -> Void) {
        self.book = book; self.save = save
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("书籍信息") {
                    TextField("书名", text: $title)
                    TextField("作者", text: $author)
                }
                Section("文件") {
                    LabeledContent("格式", value: book.format.rawValue.uppercased())
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
                }
            }
            .navigationTitle("编辑书籍")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(title, author); dismiss() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
