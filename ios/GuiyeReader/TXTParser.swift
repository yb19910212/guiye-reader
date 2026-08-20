import Foundation

struct TXTChapter: Identifiable, Hashable {
    let index: Int
    let title: String
    var id: Int { index }
}

struct TXTSearchResult: Identifiable, Hashable {
    let index: Int
    let text: String
    var id: Int { index }
}

enum TXTParser {
    static func parse(data: Data) -> [String] {
        let gb18030 = String.Encoding(rawValue: 0x8000_0632)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: gb18030)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "无法识别文本编码"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return paragraphs.isEmpty ? ["文件内容为空"] : paragraphs
    }

    static func chapters(in paragraphs: [String]) -> [TXTChapter] {
        let patterns = [
            "^第[0-9零〇一二三四五六七八九十百千万两]+[章节回卷部篇].{0,40}$",
            "^(序章|楔子|前言|序言|后记|尾声|番外|chapter\\s+[0-9]+).{0,40}$"
        ]
        let matches = paragraphs.enumerated().compactMap { index, paragraph -> TXTChapter? in
            let title = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count <= 60,
                  patterns.contains(where: { title.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
            return TXTChapter(index: index, title: title)
        }
        return matches.isEmpty ? [TXTChapter(index: 0, title: "开始阅读")] : matches
    }
}

