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

struct ReadingStatsView: View {
    @StateObject private var store = ReadingStatsStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("今日目标") {
                    HStack(spacing: 18) {
                        ProgressView(value: store.todayProgress).progressViewStyle(.circular).scaleEffect(1.5).frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("已阅读 \(Int(store.todaySeconds / 60)) 分钟").font(.headline)
                            Text("目标 \(store.goalMinutes) 分钟").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    Stepper("每日目标：\(store.goalMinutes) 分钟", value: $store.goalMinutes, in: 5...180, step: 5)
                }
                Section("连续阅读") {
                    Label("连续 \(store.streak) 天", systemImage: "flame.fill").foregroundStyle(.orange).font(.title3.weight(.semibold))
                }
                Section("最近 7 天") {
                    HStack(alignment: .bottom, spacing: 10) {
                        let days = store.lastSevenDays
                        ForEach(days.indices, id: \.self) { index in
                            let item = days[index]
                            VStack(spacing: 5) {
                                Text("\(Int(item.seconds / 60))").font(.caption2).monospacedDigit()
                                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                                    .frame(height: CGFloat(max(4, min(100, item.seconds / 60 * 3))))
                                Text(item.date.formatted(.dateTime.weekday(.narrow))).font(.caption2)
                            }.frame(maxWidth: .infinity)
                        }
                    }.frame(height: 145, alignment: .bottom).padding(.vertical, 8)
                }
                Section { Text("仅统计阅读页处于前台的时间；切到后台或退出阅读会立即停止计时。").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("阅读统计")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ReadingPlansView: View {
    let books: [Book]
    @StateObject private var store = ReadingPlanStore()
    @State private var selectedBookID = ""
    @State private var days = 30
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("新建计划") {
                    Picker("书籍", selection: $selectedBookID) { ForEach(books) { Text($0.title).tag($0.id) } }
                    Picker("完成期限", selection: $days) { ForEach([7, 14, 30, 60], id: \.self) { Text("\($0) 天").tag($0) } }.pickerStyle(.segmented)
                    Button("开始读完计划") {
                        if let book = books.first(where: { $0.id == selectedBookID }) { store.set(book: book, days: days) }
                    }.disabled(selectedBookID.isEmpty)
                }
                Section("进行中的计划") {
                    if activePlans.isEmpty { Text("还没有读完计划").foregroundStyle(.secondary) }
                    ForEach(activePlans) { plan in
                        let progress = books.first(where: { $0.id == plan.bookID })?.progress ?? 0
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(plan.bookTitle).font(.headline); Spacer(); Text("\(Int(progress * 100))%").monospacedDigit() }
                            ProgressView(value: progress)
                            Text(planSummary(plan, progress: progress)).font(.caption).foregroundStyle(progress >= 0.98 ? Color.green : Color.secondary)
                        }.swipeActions { Button("删除", role: .destructive) { store.remove(bookID: plan.bookID) } }
                    }
                }
            }
            .navigationTitle("读完计划")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { if selectedBookID.isEmpty { selectedBookID = books.first?.id ?? "" } }
        }
    }

    private var activePlans: [ReadingPlan] { store.plans.sorted { $0.deadline < $1.deadline } }
    private func planSummary(_ plan: ReadingPlan, progress: Double) -> String {
        if progress >= 0.98 { return "已完成计划" }
        let remaining = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: plan.deadline)).day ?? 0
        if remaining < 0 { return "已逾期 \(-remaining) 天 · 剩余 \(Int((1 - progress) * 100))%" }
        let daily = (1 - progress) / Double(max(remaining + 1, 1)) * 100
        return "截止 \(plan.deadline.formatted(date: .abbreviated, time: .omitted)) · 每天至少 \(String(format: "%.1f", daily))%"
    }
}

