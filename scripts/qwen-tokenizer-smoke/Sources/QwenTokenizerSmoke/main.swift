import Foundation
import Tokenizers

struct Fixture: Decodable { let text: String; let ids: [Int] }
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: folder.appendingPathComponent("tokenizer-fixtures.json")))
for fixture in fixtures {
    let actual = tokenizer.encode(text: fixture.text, addSpecialTokens: false)
    guard actual == fixture.ids else { fatalError("Swift/Python tokenizer mismatch: \(fixture.text): \(actual) vs \(fixture.ids)") }
}
print("Swift tokenizer loaded offline; \(fixtures.count) Python parity fixtures passed")
