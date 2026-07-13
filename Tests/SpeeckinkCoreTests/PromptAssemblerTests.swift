import Testing
@testable import SpeeckinkCore

@Test func systemPromptContainsCoreContract() {
    let p = PromptAssembler(language: .followSpeech).systemPrompt()
    #expect(p.contains("只整理、不回答"))
    #expect(p.contains("new_content"))
    #expect(p.contains("edit_command"))
    #expect(p.contains("undo"))
    #expect(p.contains("贅詞"))
}

@Test func intentRulesDefineAmbiguityFallbackAndEditContract() {
    let p = PromptAssembler(language: .zhTW).systemPrompt()
    #expect(p.contains("模糊") && p.contains("new_content"))          // 模糊→new_content
    #expect(p.contains("修正後的 session 全文"))                       // edit_command 的 text 契約
    #expect(p.contains("復原上一步"))                                  // undo 觸發語彙
}

@Test func layerOrderIsCoreThenLanguageThenStyle() {
    let p = PromptAssembler(language: .zhTW).systemPrompt()
    let core = p.range(of: "只整理、不回答")!
    let lang = p.range(of: "輸出語系＝繁體中文")!
    let style = p.range(of: "全形標點")!
    #expect(core.lowerBound < lang.lowerBound)
    #expect(lang.lowerBound < style.lowerBound)
}

@Test func languageRulePerSetting() {
    #expect(PromptAssembler(language: .zhCN).systemPrompt().contains("翻译成简体中文"))
    #expect(PromptAssembler(language: .english).systemPrompt().contains("MUST be entirely in English"))
    #expect(PromptAssembler(language: .followSpeech).systemPrompt().contains("跟隨使用者口述"))
}

@Test func userPayloadWithEmptySessionOmitsSessionBlock() {
    let u = PromptAssembler(language: .zhTW).userPayload(utteranceRaw: "呃你好", context: .session(""))
    #expect(u.contains("呃你好"))
    #expect(u.contains("本段轉錄"))
    #expect(!u.contains("session 現有全文"))
    #expect(u.contains("目前沒有可修正的既有內容"))   // 明示首句不可能是修正
}

@Test func userPayloadWithSessionIncludesFullText() {
    let u = PromptAssembler(language: .zhTW).userPayload(utteranceRaw: "欸星期二改成星期三", context: .session("我們星期二開會。"))
    #expect(u.contains("session 現有全文"))
    #expect(u.contains("我們星期二開會。"))
    #expect(u.contains("欸星期二改成星期三"))
}

@Test func selectionPayloadCarriesTargetAndInstruction() {
    let p = PromptAssembler(language: .followSpeech)
    let payload = p.userPayload(utteranceRaw: "改正式一點",
                                context: .selection("嗨大家明天聚一下", before: "主旨：", after: "謝謝。"))
    #expect(payload.contains("使用者選取了以下文字"))
    #expect(payload.contains("嗨大家明天聚一下"))
    #expect(payload.contains("改正式一點"))
    #expect(payload.contains("主旨："))
    #expect(payload.contains("謝謝。"))
    #expect(!payload.contains("session 現有全文"))
}

@Test func sessionPayloadWithCaretContextAppendsWindows() {
    let p = PromptAssembler(language: .followSpeech)
    let payload = p.userPayload(utteranceRaw: "繼續寫",
                                context: IntentContext(targetKind: .session, targetText: "",
                                                       contextBefore: "前情提要", contextAfter: nil))
    #expect(payload.contains("目前沒有可修正的既有內容"))
    #expect(payload.contains("前情提要"))
    #expect(!payload.contains("游標後文"))            // 沒給就不出現空區塊
}

@Test func sessionPayloadWithoutContextUnchangedFromM2() {
    let p = PromptAssembler(language: .followSpeech)
    let payload = p.userPayload(utteranceRaw: "你好", context: .session("既有全文"))
    #expect(payload.contains("session 現有全文：\n既有全文"))
    #expect(payload.contains("本段轉錄：\n你好"))
}
