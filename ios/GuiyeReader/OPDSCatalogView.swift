import ReadiumOPDS
import ReadiumShared
import SwiftUI

@MainActor
final class OPDSCatalogModel: ObservableObject {
    @Published var feed: Feed?
    @Published var isLoading = false
    @Published var message: String?

    func load(_ address: String) {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            message = "请输入有效的 HTTP(S) OPDS 地址"; return
        }
        isLoading = true; message = nil; feed = nil
        OPDSParser.parseURL(url: url) { [weak self] data, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let feed = data?.feed { self?.feed = feed }
                else { self?.message = error?.localizedDescription ?? "无法解析 OPDS 目录" }
            }
        }
    }
}

struct OPDSCatalogView: View {
    @ObservedObject var repository: BookRepository
    @StateObject private var model = OPDSCatalogModel()
    @AppStorage("opds.lastURL") private var address = "https://standardebooks.org/opds/all"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            catalogList
            .navigationTitle("OPDS 书库")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var catalogList: some View {
        List {
            addressSection
            if let feed = model.feed { feedSections(feed) }
        }
    }

    private var addressSection: some View {
        Section {
            TextField("OPDS 目录地址", text: $address).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("打开目录") { model.load(address.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(model.isLoading)
            if model.isLoading { ProgressView() }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func feedSections(_ feed: Feed) -> some View {
        let links = navigation(feed)
        if !links.isEmpty {
            Section("浏览") {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button { address = link.href; model.load(link.href) } label: { Label(link.title ?? link.href, systemImage: "chevron.right") }
                }
            }
        }
        Section(feed.metadata.title) {
            ForEach(Array(publications(feed).enumerated()), id: \.offset) { _, publication in publicationRow(publication) }
        }
    }

    private func publicationRow(_ publication: Publication) -> some View {
        let title = publication.metadata.title ?? "未命名出版物"
        let author = publication.metadata.authors.map(\.name).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            if !author.isEmpty { Text(author).font(.subheadline).foregroundStyle(.secondary) }
            if let link = publication.downloadLinks.first {
                Button("下载并导入") { download(title, link: link) }
            } else {
                Text("没有可直接下载的无 DRM 文件").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func navigation(_ feed: Feed) -> [ReadiumShared.Link] { feed.navigation + feed.groups.flatMap(\.navigation) }
    private func publications(_ feed: Feed) -> [Publication] { feed.publications + feed.groups.flatMap(\.publications) }

    private func download(_ title: String, link: ReadiumShared.Link) {
        guard let url = URL(string: link.href) else { model.message = "下载地址无效"; return }
        model.message = "正在下载《\(title)》…"
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url)
                let suggested = response.suggestedFilename ?? url.lastPathComponent
                let ext = suggested.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
                guard ["epub", "pdf", "txt"].contains(ext) else { throw OPDSImportError.unsupported }
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(suggested)")
                try FileManager.default.moveItem(at: temporary, to: target)
                repository.importFiles([target])
                model.message = "已开始导入《\(title)》"
            } catch { model.message = error.localizedDescription }
        }
    }
}

private enum OPDSImportError: LocalizedError {
    case unsupported
    var errorDescription: String? { "此出版物不是可导入的 EPUB、PDF 或 TXT" }
}
