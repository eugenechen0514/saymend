import Foundation

/// 統一的「單輪指令進、文字出」LLM 介面（規格 §4.3）
public protocol LLMProvider {
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String
}

public enum LLMError: Error, Equatable {
    case badStatus(Int)
    case emptyResponse
    case timedOut          // M7 §3：兩個 provider 的內部逾時統一映射到此
}
