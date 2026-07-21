import Foundation
@testable import SaymendCore

/// M4 prompt 字面的測試 fixture 載入器。M5 Task 4 拆 coreRules 後，
/// 「純聽寫整理」內建模式的 systemRules 必須與從 JSON fixture 載入的
/// legacyCoreRules 字面完全相等。
struct GoldenDefaultFixture: Codable {
    let language: OutputLanguage
    let legacyCoreRules: String
    let languageRule: String
    let styleRules: String

    static let all: [GoldenDefaultFixture] = {
        // 資源需透過 SwiftPM 自動產生的 `Bundle.module` 存取（此 target 已在
        // Package.swift 宣告 resources）；`Bundle(for:)` 解到的是 .xctest 本體，
        // 不是 SwiftPM 的 resource bundle。per-file `.copy` 會把檔案攤平到
        // bundle 根目錄，不保留 Fixtures/CoreMode/ 的原始目錄結構，因此這裡
        // 不指定 subdirectory，改用檔名前綴過濾。
        let urls = Bundle.module.urls(forResourcesWithExtension: "json",
                                      subdirectory: nil)?
            .filter { $0.lastPathComponent.hasPrefix("golden-default.") } ?? []
        return urls.compactMap { url -> GoldenDefaultFixture? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(GoldenDefaultFixture.self, from: data)
        }
    }()
}
