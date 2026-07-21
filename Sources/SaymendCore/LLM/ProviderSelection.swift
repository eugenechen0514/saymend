import Foundation

/// LLM provider 選擇（spec §3.1）。加新 provider＝加一個 case ＋ router 一路。
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompat
    case claudeCLI
}

/// ClaudeCLI 設定（spec §4.1）。cliPathOverride=nil ＝ 自動偵測。
public struct ClaudeCLIConfig: Equatable, Sendable {
    public var cliPathOverride: String?
    public var model: String

    public init(cliPathOverride: String? = nil, model: String = "sonnet") {   // spike 定案：sonnet 0/16 圍欄且更快
        self.cliPathOverride = cliPathOverride
        self.model = model
    }
}
