import Foundation

/// Provider 測試結果（M7 spec §5.4）
public struct ProviderTestReport: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case ok
        case badEnvelope(String)      // strict parser 拒收或 intent 非法（空殼 provider 死在這關）
        case failed(String)           // §3.3 同語彙的失敗原因
    }
    public var verdict: Verdict
    public var latency: TimeInterval?          // 連上了才有
    public var exceedsPolishTimeout: Bool

    public init(verdict: Verdict, latency: TimeInterval?, exceedsPolishTimeout: Bool) {
        self.verdict = verdict
        self.latency = latency
        self.exceedsPolishTimeout = exceedsPolishTimeout
    }
}

/// Provider 連通性測試（M7 spec §5）：完整往返＋三判定（連通／延遲 vs polishTimeout／信封）。
/// 走真實 PromptAssembler——M6 教訓：簡化 prompt 的結論在真實 ~4KB prompt 上會翻車。
/// timeout 用 120s 上限、刻意不用 polishTimeout：要量出慢 provider 的真實延遲數字，
/// 用 3s 測只會得到「逾時」而量不到 6.6s。
public struct ProviderTester: Sendable {
    public static let sampleUtterance = "今天天氣很好然後我想說就是去公園走走"
    public static let testTimeout: TimeInterval = 120     // AppSettings.timeoutRange 上限

    private let provider: any RoutedLLMProvider
    public init(provider: any RoutedLLMProvider) { self.provider = provider }

    public func run(kind: ProviderKind, polishTimeout: TimeInterval) async -> ProviderTestReport {
        // 與 IntentService 同一條組裝路徑（validatedPrompt 含 budget 檢查），不另開路造成漂移
        let assembler = PromptAssembler(language: .followSpeech,
                                        sources: PromptLayerSources(),
                                        mode: PromptAssembler.pureDictationMode)
        let prompt: (system: String, user: String)
        do {
            prompt = try assembler.validatedPrompt(utteranceRaw: Self.sampleUtterance,
                                                   context: IntentContext(),
                                                   budget: PromptBudget())
        } catch {
            return ProviderTestReport(verdict: .failed("Prompt 組裝失敗"),
                                      latency: nil, exceedsPolishTimeout: false)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let raw: String
        do {
            raw = try await provider.complete(kind: kind, system: prompt.system,
                                              user: prompt.user, timeout: Self.testTimeout)
        } catch {
            return ProviderTestReport(verdict: .failed(degradedReason(for: error, timeout: Self.testTimeout)),
                                      latency: nil, exceedsPolishTimeout: false)
        }
        let latency = Self.seconds(clock.now - start)
        let exceeds = latency > polishTimeout

        switch EnvelopeParser.parse(raw, mode: .strict) {
        case .success(let envelope):
            guard ["new_content", "edit_command", "undo"].contains(envelope.intent) else {
                return ProviderTestReport(verdict: .badEnvelope("意圖非合約列舉值"),
                                          latency: latency, exceedsPolishTimeout: exceeds)
            }
            return ProviderTestReport(verdict: .ok, latency: latency, exceedsPolishTimeout: exceeds)
        case .failure:
            return ProviderTestReport(verdict: .badEnvelope("回應格式不合法"),
                                      latency: latency, exceedsPolishTimeout: exceeds)
        }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
