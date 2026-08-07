import ReadiumOPDS
import ReadiumShared
import SwiftUI
import Foundation

@MainActor
final class OPDSCatalogModel: ObservableObject {
    @Published var feed: Feed?
    @Published var isLoading = false
    @Published var message: String?

    func load(_ address: String, username: String = "", password: String = "") {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            message = "请输入有效的 HTTP(S) OPDS 地址"; return
        }
        guard username.isEmpty || url.scheme?.lowercased() == "https" else { message = "使用账号时必须使用 HTTPS 地址"; return }
        isLoading = true; message = nil; feed = nil
        var request = URLRequest(url: url, timeoutInterval: 60)
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] body, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                guard let body, let response else { self?.message = error?.localizedDescription ?? "无法连接 OPDS 目录"; return }
                let data = (try? OPDS1Parser.parse(xmlData: body, url: url, response: response))
                    ?? (try? OPDS2Parser.parse(jsonData: body, url: url, response: response))
                if let feed = data?.feed { self?.feed = feed }
                else { self?.message = "无法解析 OPDS 目录，请检查地址或账号" }
            }
        }.resume()
    }
}

struct OPDSCatalogView: View {
    @ObservedObject var repository: BookRepository
    @StateObject private var model = OPDSCatalogModel()
    @AppStorage("opds.lastURL") private var address = "https://standardebooks.org/opds/all"
    @State private var username = ""
    @State private var password = ""
    @State private var query = ""
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
            TextField("用户名（可选）", text: $username).textInputAutocapitalization(.never)
            SecureField("密码（仅本次使用）", text: $password)
            Button("打开目录") { model.load(address.trimmingCharacters(in: .whitespacesAndNewlines), username: username, password: password) }.disabled(model.isLoading)
            if model.isLoading { ProgressView() }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            if model.feed != nil { TextField("筛选书名或作者", text: $query) }
        }
    }

    @ViewBuilder private func feedSections(_ feed: Feed) -> some View {
        let links = navigation(feed)
        if !links.isEmpty {
            Section("浏览") {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button { address = link.href; model.load(link.href, username: username, password: password) } label: { Label(link.title ?? link.href, systemImage: "chevron.right") }
                }
            }
        }
        Section(feed.metadata.title) {
            ForEach(Array(filteredPublications(feed).enumerated()), id: \.offset) { _, publication in publicationRow(publication) }
        }
    }

    private func publicationRow(_ publication: Publication) -> some View {
        let title = publication.metadata.title ?? "未命名出版物"
        let author = publication.metadata.authors.map(\.name).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            if !author.isEmpty { Text(author).font(.subheadline).foregroundStyle(.secondary) }
            if let link = downloadableLink(in: publication) {
                Button("下载并导入") { download(title, link: link) }
            } else {
                Text("没有可直接下载的无 DRM 文件").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func downloadableLink(in publication: Publication) -> ReadiumShared.Link? {
        publication.links.first { link in
            let mediaType = link.mediaType?.string.lowercased() ?? ""
            let ext = URL(string: link.href)?.pathExtension.lowercased() ?? ""
            let supported = mediaType.contains("epub") || mediaType.contains("pdf") || mediaType.contains("text/plain") || ["epub", "pdf", "txt"].contains(ext)
            let acquisition = link.rels.contains(.opdsAcquisition) || link.rels.contains(.opdsAcquisitionOpenAccess)
            return supported && acquisition
        }
    }

    private func navigation(_ feed: Feed) -> [ReadiumShared.Link] { feed.navigation + feed.groups.flatMap(\.navigation) }
    private func publications(_ feed: Feed) -> [Publication] { feed.publications + feed.groups.flatMap(\.publications) }

    private func filteredPublications(_ feed: Feed) -> [Publication] {
        guard !query.isEmpty else { return publications(feed) }
        return publications(feed).filter {
            ($0.metadata.title?.localizedCaseInsensitiveContains(query) == true)
                || $0.metadata.authors.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    private func download(_ title: String, link: ReadiumShared.Link) {
        guard let url = URL(string: link.href) else { model.message = "下载地址无效"; return }
        model.message = "正在下载《\(title)》…"
        Task {
            do {
                var request = URLRequest(url: url, timeoutInterval: 120)
                if !username.isEmpty {
                    let token = Data("\(username):\(password)".utf8).base64EncodedString()
                    request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
                }
                let (temporary, response) = try await URLSession.shared.download(for: request)
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
