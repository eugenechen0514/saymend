import Foundation

/// kind 由呼叫端逐次傳入（出自 IntentService 的單一快照）——router 不自行讀取狀態，
/// 「同一句話的路由與 timeout 出自同一次讀取」在構造上成立（spec §3.2/§5）。
public protocol RoutedLLMProvider: Sendable {
    func complete(kind: ProviderKind, system: String, user: String,
                  timeout: TimeInterval) async throws -> String
}

public final class ProviderRouter: RoutedLLMProvider, @unchecked Sendable {
    private let openAICompat: any LLMProvider
    private let claudeCLI: any LLMProvider

    public init(openAICompat: any LLMProvider, claudeCLI: any LLMProvider) {
        self.openAICompat = openAICompat
        self.claudeCLI = claudeCLI
    }

    public func complete(kind: ProviderKind, system: String, user: String,
                         timeout: TimeInterval) async throws -> String {
        switch kind {
        case .openAICompat: return try await openAICompat.complete(system: system, user: user, timeout: timeout)
        case .claudeCLI: return try await claudeCLI.complete(system: system, user: user, timeout: timeout)
        }
    }
}
