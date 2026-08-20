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
        let chapters = TXTParser.chapters(in: ["前言", "内容", "第一章 初见", "Chapter 2 Return", "尾声"])
        precondition(chapters.map(\.index) == [0, 2, 3, 4])
        precondition(TXTParser.chapters(in: ["只有正文"]) == [TXTChapter(index: 0, title: "开始阅读")])
        print("TXTParserSmoke OK: \(data.count) bytes, \(paragraphs.count) paragraphs, \(elapsed)s")
    }
}

