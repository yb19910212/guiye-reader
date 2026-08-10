import Foundation

@main
struct TXTParserSmoke {
    static func main() throws {
        let line = "这是用于验证长篇 TXT 不阻塞界面的性能测试段落。阅读进度和语音功能必须保持可用。\n"
        let data = Data(String(repeating: line, count: 30_000).utf8)
        precondition(data.count > 2_000_000)
        let started = Date()
        let paragraphs = TXTParser.parse(data: data)
        let elapsed = Date().timeIntervalSince(started)
        precondition(paragraphs.count == 30_000)
        precondition(elapsed < 3.0, "TXT parsing took \(elapsed)s")
        print("TXTParserSmoke OK: \(data.count) bytes, \(paragraphs.count) paragraphs, \(elapsed)s")
    }
}
