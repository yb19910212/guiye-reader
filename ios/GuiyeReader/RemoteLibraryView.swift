import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct WebDAVItem: Identifiable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var id: String { url.absoluteString }
    var isBook: Bool { ["epub", "pdf", "txt"].contains(url.pathExtension.lowercased()) }
}

private final class WebDAVParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private(set) var items: [WebDAVItem] = []
    private var href = ""
    private var displayName = ""
    private var isCollection = false
    private var text = ""

    init(baseURL: URL) { self.baseURL = baseURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        text = ""
        if elementName.lowercased().hasSuffix("response") { href = ""; displayName = ""; isCollection = false }
        if elementName.lowercased().hasSuffix("collection") { isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name.hasSuffix("href") { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name.hasSuffix("displayname") { displayName = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard name.hasSuffix("response"), let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { return }
        let cleanName = displayName.isEmpty ? url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent : displayName
        items.append(WebDAVItem(url: url, name: cleanName.isEmpty ? "/" : cleanName, isDirectory: isCollection))
    }
}

@MainActor
final class WebDAVModel: ObservableObject {
    @Published var items: [WebDAVItem] = []
    @Published var currentURL: URL?
    @Published var isLoading = false
    @Published var message: String?

    func open(_ address: String, username: String, password: String) {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https" else {
            message = "请输入 HTTPS WebDAV 地址"; return
        }
        isLoading = true; message = nil
        Task {
            do {
                var request = URLRequest(url: url, timeoutInterval: 60)
                request.httpMethod = "PROPFIND"
                request.setValue("1", forHTTPHeaderField: "Depth")
                request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>".utf8)
                authorize(&request, username: username, password: password)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 207 else { throw WebDAVError.connection }
                let delegate = WebDAVParser(baseURL: url)
                let parser = XMLParser(data: data); parser.delegate = delegate
                guard parser.parse() else { throw parser.parserError ?? WebDAVError.invalidResponse }
                let normalized = url.standardized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                items = delegate.items.filter { $0.url.standardized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != normalized }
                    .filter { $0.isDirectory || $0.isBook }.sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                currentURL = url
            } catch { message = error.localizedDescription }
            isLoading = false
        }
    }

    func download(_ items: [WebDAVItem], username: String, password: String, repository: BookRepository) {
        guard !items.isEmpty else { message = "当前文件夹没有可导入的书籍"; return }
        isLoading = true; message = "正在下载 (items.count) 本书…"
        Task {
            var urls: [URL] = []
            do {
                for item in items {
                    var request = URLRequest(url: item.url, timeoutInterval: 180)
                    authorize(&request, username: username, password: password)
                    let (temporary, response) = try await URLSession.shared.download(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw WebDAVError.connection }
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(item.name)")
                    try FileManager.default.moveItem(at: temporary, to: target)
                    urls.append(target)
                }
                repository.importFiles(urls)
                message = "已下载，正在加入本地书库"
            } catch { message = error.localizedDescription }
            isLoading = false
        }
    }

    private func authorize(_ request: inout URLRequest, username: String, password: String) {
        guard !username.isEmpty else { return }
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }
}

struct RemoteLibraryView: View {
    @ObservedObject var repository: BookRepository
    @StateObject private var model = WebDAVModel()
    @AppStorage("webdav.lastURL") private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showsSystemFiles = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("WebDAV") {
                    TextField("https://服务器/dav/文件夹/", text: $address).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("用户名（可选）", text: $username).textInputAutocapitalization(.never)
                    SecureField("密码（仅本次使用）", text: $password)
                    Button("打开远程文件夹") { model.open(address.trimmingCharacters(in: .whitespacesAndNewlines), username: username, password: password) }
                    if model.isLoading { ProgressView() }
                    if let message = model.message { Text(message).foregroundStyle(.secondary) }
                    if model.items.contains(where: { !$0.isDirectory && $0.isBook }) {
                        Button("导入当前文件夹全部书籍") { model.download(model.items.filter { !$0.isDirectory && $0.isBook }, username: username, password: password, repository: repository) }
                    }
                }
                if !model.items.isEmpty {
                    Section(model.currentURL?.lastPathComponent.removingPercentEncoding ?? "远程文件") {
                        ForEach(model.items) { item in
                            Button {
                                if item.isDirectory { address = item.url.absoluteString; model.open(address, username: username, password: password) }
                                else { model.download([item], username: username, password: password, repository: repository) }
                            } label: { Label(item.name, systemImage: item.isDirectory ? "folder" : "book.closed") }
                        }
                    }
                }
                Section("SMB 网络文件夹") {
                    Text("iOS 的 SMB 由“文件”App 统一管理。先在“文件”App 右上角菜单选择“连接服务器”，添加 smb:// 地址；随后可在这里直接浏览并批量导入。")
                    Button("打开系统文件 / SMB") { showsSystemFiles = true }
                }
            }
            .navigationTitle("网络书库")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showsSystemFiles) {
                DocumentPicker(contentTypes: [.plainText, .text, .pdf, UTType(filenameExtension: "epub") ?? .data], onPicked: { urls in
                    showsSystemFiles = false; repository.importFiles(urls)
                }, onFailure: { error in repository.lastError = error.localizedDescription })
            }
        }
    }
}

private enum WebDAVError: LocalizedError {
    case connection, invalidResponse
    var errorDescription: String? {
        switch self {
        case .connection: "无法连接 WebDAV，请检查地址、账号和服务器证书"
        case .invalidResponse: "WebDAV 返回内容无法解析"
        }
    }
}
