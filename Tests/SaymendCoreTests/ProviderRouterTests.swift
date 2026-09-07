import Foundation
import Testing
@testable import SaymendCore

/// 記錄型假 sub-provider（以內容為 key 的紀律不適用——router 測試只驗「誰被呼叫」）
final class RecordingProvider: LLMProvider, @unchecked Sendable {
    let name: String
    private(set) var calls: [(system: String, user: String, timeout: TimeInterval)] = []
    init(_ name: String) { self.name = name }
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        calls.append((system, user, timeout))
        return name
    }
}

@Test func routerDelegatesByKind() async throws {
    let oai = RecordingProvider("oai"), cli = RecordingProvider("cli")
    let r = ProviderRouter(openAICompat: oai, claudeCLI: cli)
    #expect(try await r.complete(kind: .openAICompat, system: "s", user: "u", timeout: 3) == "oai")
    #expect(try await r.complete(kind: .claudeCLI, system: "s", user: "u", timeout: 15) == "cli")
    #expect(oai.calls.count == 1 && cli.calls.count == 1)
    // 不可直接 `[0]`：`#expect` 失敗不會中止函式，cli 沒被呼叫時索引會讓整個測試行程
    // 以 signal 5 結束、排在後面的測試全部沒跑（issue #68）。
    guard let cliCall = cli.calls.first else {
        Issue.record("cli 應被呼叫恰一次；實際 \(cli.calls.count) 次")
        return
    }
    #expect(cliCall.timeout == 15)                                  // timeout 原樣透傳
}
