import Foundation

@main struct SpeechQueueSmoke {
    static func main() {
        let texts = ["", "   ", "短句。", String(repeating: "中文😀没有标点", count: 600), "First sentence. Second sentence! 末尾。"]
        for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var cursor = SpeechChunkCursor(segments: [.init(id: 17, text: text, languageTag: "zh-CN")], from: 0)
            var joined = ""
            while let chunk = cursor.next() {
                precondition(chunk.id == 17 && chunk.text.count <= 48)
                joined += chunk.text
            }
            precondition(joined == text)
            precondition(cursor.next() == nil)
        }
        var cursor = SpeechChunkCursor(segments: [.init(id: 0, text: "skip", languageTag: "en"), .init(id: 9, text: "read", languageTag: "en")], from: 1)
        precondition(cursor.next()?.id == 9)
        precondition(cursor.next() == nil)
        var window = SpeechPrefetchWindow()
        for expected in 0..<10_000 {
            while window.canRequest { _ = window.reserve() }
            precondition(window.requested - window.played == 3)
            precondition(window.reserve() == nil)
            precondition(window.played == expected)
            window.advance()
        }
        var old: [SpeechCancellation] = []
        var current = SpeechCancellation()
        for _ in 0..<1000 { old.append(current); current.cancel(); current = SpeechCancellation() }
        precondition(old.allSatisfy { $0.isCancelled } && !current.isCancelled)
        print("Speech cursor/window/cancellation smoke checks passed")
    }
}
