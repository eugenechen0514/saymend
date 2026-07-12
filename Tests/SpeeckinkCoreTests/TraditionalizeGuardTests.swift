import Testing
@testable import SpeeckinkCore

@Test func zhTWModeConvertsSimplifiedToTraditional() throws {
    let g = try TraditionalizeGuard()
    #expect(g.apply("干净的代码", language: .zhTW) == "乾淨的程式碼" || g.apply("干净的代码", language: .zhTW) == "乾淨的代碼")
    // OpenCC twIdiom 是否把「代码→程式碼」視版本而定，兩者皆可接受；重點是簡字必須消失
    #expect(!g.apply("干净", language: .zhTW).contains("干净"))
}

@Test func otherLanguagesPassThrough() throws {
    let g = try TraditionalizeGuard()
    #expect(g.apply("干净", language: .zhCN) == "干净")
    #expect(g.apply("干净", language: .followSpeech) == "干净")
    #expect(g.apply("clean", language: .english) == "clean")
}

@Test func outputLanguageRawValuesStable() {
    // rawValue 會進 UserDefaults，不得改動
    #expect(OutputLanguage.followSpeech.rawValue == "followSpeech")
    #expect(OutputLanguage.zhTW.rawValue == "zhTW")
    #expect(OutputLanguage.zhCN.rawValue == "zhCN")
    #expect(OutputLanguage.english.rawValue == "english")
}
