import Testing
@testable import SpeeckinkCore

@Test func truncatedVariableLayersNeverTouchContract() throws {
    // 構造逼近 budget 的 systemRules + 大 style + app + vocab，迫使 trimmed 縮減可變層
    let bigStyle = String(repeating: "中文與英文之間補半形空格。", count: 1000)
    let bigCustom = String(repeating: "每句加 --E ", count: 1000)
    let a = PromptAssembler(
        language: .followSpeech,
        sources: PromptLayerSources(
            styleOverride: bigStyle,
            customPrompt: bigCustom,
            appPrompt: "目標 Slack 訊息",
            vocab: [VocabEntry(phrase: "openpets")]),
        mode: PromptAssembler.pureDictationMode)
    // 原始組裝約 57KB（bigStyle 39KB + bigCustom 14.5KB 為大宗），遠超 34_000；
    // 逐層各縮一次後（vocab→app→custom→style）約 30.5KB，落在 34_000 以內——
    // budget 值經實測校準，確保真的觸發縮減、而非縮完仍全部超標（plan 原給的
    // 10_000 太嚴，逐層各縮一次後仍遠超標，會誤觸發 variableLayersTruncatedButStillOver）。
    let budget = PromptBudget(
        maxSystemUTF8Bytes: 34_000,
        maxUserUTF8Bytes: 64_000,
        maxTotalUTF8Bytes: 96_000,
        machineContractReserve: 2_048)
    let trimmed = try a.trimmedSystemPrompt(budget: budget)
    #expect(trimmed.hasSuffix(PromptAssembler.machineContract))
    let endMarker = "==== MACHINE CONTRACT END ===="
    #expect(trimmed.hasSuffix(endMarker))
    let suffix = trimmed.suffix(PromptAssembler.machineContract.count)
    #expect(suffix == PromptAssembler.machineContract)
}

@Test func variableLayersShrunkWhenOverBudget() throws {
    let bigStyle = String(repeating: "中英空格。", count: 500)
    let a = PromptAssembler(
        language: .followSpeech,
        sources: PromptLayerSources(styleOverride: bigStyle),
        mode: PromptAssembler.pureDictationMode)
    // 原始組裝約 11.2KB，超過 8_500；style 縮一次後約 7.4KB，落在範圍內——
    // budget 值經實測校準（plan 原給的 4_000 連 behavior+contract 都放不下，
    // 縮完仍會超標）。
    let budget = PromptBudget(
        maxSystemUTF8Bytes: 8_500,
        maxUserUTF8Bytes: 64_000,
        maxTotalUTF8Bytes: 96_000,
        machineContractReserve: 1_024)
    let trimmed = try a.trimmedSystemPrompt(budget: budget)
    #expect(trimmed.contains("…[truncated]"))
}

@Test func promptTooLongErrorWhenContractAloneOver() {
    let a = PromptAssembler(language: .followSpeech,
                            mode: PromptAssembler.pureDictationMode)
    // machineContractReserve 故意小於實際 contract bytes
    let budget = PromptBudget(
        maxSystemUTF8Bytes: 4_000,
        maxUserUTF8Bytes: 64_000,
        maxTotalUTF8Bytes: 96_000,
        machineContractReserve: 100)
    #expect(throws: PromptTooLongError.machineContractAloneExceedsBudget) {
        _ = try a.trimmedSystemPrompt(budget: budget)
    }
}
