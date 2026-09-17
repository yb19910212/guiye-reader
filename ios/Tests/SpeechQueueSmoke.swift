import Foundation

@main struct SpeechQueueSmoke {
    static func main() async throws {
        let texts = ["", "   ", "短句。", String(repeating: "中文😀没有标点", count: 600), "First sentence. Second sentence! 末尾。"]
        for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var cursor = SpeechChunkCursor(segments: [.init(id: 17, text: text, languageTag: "zh-CN")], from: 0)
            var joined = ""
            while let chunk = cursor.next() {
                precondition(chunk.id == 17 && chunk.text.count <= 80)
                joined += chunk.text
            }
            precondition(joined == text)
            precondition(cursor.next() == nil)
        }
        let sentence = String(repeating: "长", count: 70) + "。"
        var complete = SpeechChunkCursor(segments: [.init(id: 1, text: sentence, languageTag: "zh")], from: 0)
        precondition(complete.next()?.text == sentence)
        var wav = Data("RIFF".utf8)
        func le(_ value: Int, _ count: Int) { for i in 0..<count { wav.append(UInt8((value >> (i * 8)) & 255)) } }
        le(40, 4); wav.append(contentsOf: "WAVEfmt ".utf8); le(16, 4); le(1, 2); le(1, 2)
        le(24000, 4); le(48000, 4); le(2, 2); le(16, 2); wav.append(contentsOf: "data".utf8); le(4, 4); le(0, 4)
        precondition((try? SpeechWAV.duration(wav)) != nil)
        precondition((try? SpeechWAV.duration(Data(wav.dropLast()))) == nil)
        precondition((try? SpeechWAV.duration(Data())) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guiye-cache-test-" + UUID().uuidString)
        let cache = SpeechDiskCache(directory: directory)
        let file = try await cache.file(identity: "server|voice1|text")
        let other = try await cache.file(identity: "server|voice4|text")
        precondition(file != other)
        let missing = await cache.read(file); precondition(missing == nil)
        _ = try await cache.save(wav, to: file)
        let reopened = SpeechDiskCache(directory: directory)
        let restored = await reopened.read(file); precondition(restored != nil)
        do { _ = try await cache.save(Data(wav.dropLast()), to: other); preconditionFailure("accepted truncated audio") } catch {}
        let absent = await cache.read(other); precondition(absent == nil)
        try await cache.clear()
        precondition(!FileManager.default.fileExists(atPath: directory.path))
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
