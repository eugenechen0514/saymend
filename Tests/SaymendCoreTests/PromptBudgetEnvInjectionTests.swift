import Foundation
import Testing
@testable import SaymendCore

/// 這三個測試都突變同一個全域環境變數 SPEECKINK_E2E_PROMPT_BUDGET_JSON。
/// Swift Testing 預設並行執行，會讓它們互相污染 env（一個 unset 後、另一個又 set），
/// 因此標 `.serialized` 讓本 suite 內串行執行——env 是進程全域可變狀態，沒有其他隔離方式。
@Suite(.serialized)
struct PromptBudgetEnvInjectionTests {

    @Test func promptBudgetEnvInjectionIsDebugOnly() {
        let json = #"{"maxSystemUTF8Bytes":1234,"maxUserUTF8Bytes":2345,"maxTotalUTF8Bytes":3456,"machineContractReserve":789}"#
        setenv("SPEECKINK_E2E_PROMPT_BUDGET_JSON", json, 1)
        defer { unsetenv("SPEECKINK_E2E_PROMPT_BUDGET_JSON") }

        let b = PromptBudget.productionDefault()

        #if DEBUG
        // Debug：env 生效，供 E2E 第 8 項注入小 budget 觸發縮減／錯誤
        #expect(b.maxSystemUTF8Bytes == 1234)
        #expect(b.maxUserUTF8Bytes == 2345)
        #expect(b.maxTotalUTF8Bytes == 3456)
        #expect(b.machineContractReserve == 789)
        #else
        // Release：**必須完全忽略** env（規格 §7.5）
        #expect(b == PromptBudget())
        #endif
    }

    @Test func promptBudgetWithoutEnvIsProductionDefault() {
        unsetenv("SPEECKINK_E2E_PROMPT_BUDGET_JSON")
        #expect(PromptBudget.productionDefault() == PromptBudget())
    }

    @Test func promptBudgetIgnoresMalformedEnv() {
        setenv("SPEECKINK_E2E_PROMPT_BUDGET_JSON", "not json", 1)
        defer { unsetenv("SPEECKINK_E2E_PROMPT_BUDGET_JSON") }
        // 壞 JSON 一律回 production 預設（不得半套用、不得 crash）
        #expect(PromptBudget.productionDefault() == PromptBudget())
    }
}
