import Foundation
@testable import SaymendCore

/// EnvelopeParser 對抗性測試語料（105 向量，由多個角度的攻擊面生成後對真實 parser 執行過）。
/// `expected` 是 SPEC 合規的理想行為；少數向量是已知限制（見 EnvelopeParserAdversarialTests
/// 裡的 knownDeviations），實際行為與 expected 不同，测试對那幾筆改斷言實際行為，
/// 並附註「一旦修好、這裡的斷言要跟著更新」，避免日後修好了卻沒人發現。
struct AdversarialVector: Codable {
    let category: String
    let descr: String
    let codepoints: [UInt32]
    let expected: String
    let rationale: String
    let lens: String

    var raw: String {
        String(String.UnicodeScalarView(codepoints.compactMap(Unicode.Scalar.init)))
    }
}

struct AdversarialCorpus {
    static let all: [AdversarialVector] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil)?
            .filter { $0.lastPathComponent == "envelope-corpus.json" } ?? []
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AdversarialVector].self, from: data)) ?? []
    }()
}
