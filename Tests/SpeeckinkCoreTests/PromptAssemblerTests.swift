import Testing
@testable import SpeeckinkCore

@Test func systemPromptContainsCoreContract() {
    let p = PromptAssembler(language: .followSpeech).systemPrompt()
    #expect(p.contains("只整理、不回答"))
    #expect(p.contains(#"{"intent":"new_content","text":"#))
    #expect(p.contains("贅詞"))
}

@Test func layerOrderIsCoreThenLanguageThenStyle() {
    let p = PromptAssembler(language: .zhTW).systemPrompt()
    let core = p.range(of: "只整理、不回答")!
    let lang = p.range(of: "一律使用繁體中文")!
    let style = p.range(of: "全形標點")!
    #expect(core.lowerBound < lang.lowerBound)
    #expect(lang.lowerBound < style.lowerBound)
}

@Test func languageRulePerSetting() {
    #expect(PromptAssembler(language: .zhCN).systemPrompt().contains("一律使用简体中文"))
    #expect(PromptAssembler(language: .english).systemPrompt().contains("output in natural English"))
    #expect(PromptAssembler(language: .followSpeech).systemPrompt().contains("跟隨使用者口述"))
}

@Test func userPayloadWrapsRawTranscript() {
    let u = PromptAssembler(language: .zhTW).userPayload(utteranceRaw: "呃我想說 hello")
    #expect(u.contains("呃我想說 hello"))
    #expect(u.contains("原始轉錄"))
}
