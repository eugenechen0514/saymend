import Foundation

public struct CoreMode: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var systemRules: String
    public var updatedAt: Date
    public let isBuiltin: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        systemRules: String,
        updatedAt: Date = Date(),
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemRules = systemRules
        self.updatedAt = updatedAt
        self.isBuiltin = isBuiltin
    }
}

extension CoreMode {
    /// 是否附加「不可回答」的自訂層警語。內建模式以 ID 為確定性 policy；
    /// 使用者自建模式預設 false（由其 systemRules 自行決定）。
    public var enforcesNoAnswerCustomGuard: Bool {
        [
            PromptAssembler.pureDictationMode.id,
            PromptAssembler.verbatimTranscriptMode.id,
            PromptAssembler.conciseFormalRewriteMode.id,
        ].contains(id)
    }
}
