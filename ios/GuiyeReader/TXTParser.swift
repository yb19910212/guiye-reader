import Foundation

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
}
