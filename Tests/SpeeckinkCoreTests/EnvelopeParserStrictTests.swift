import Testing
@testable import SpeeckinkCore

@Test func envelopeParserStrictModeRejectsFencedJSON() {
    let raw = "```json\n{\"intent\":\"new_content\",\"text\":\"嗨\"}\n```"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受 fenced JSON")
    }
}

@Test func envelopeParserStrictModeRejectsLeadingProse() {
    let raw = "好的，以下是結果：{\"intent\":\"new_content\",\"text\":\"嗨\"}"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受 leading prose")
    }
}

@Test func envelopeParserStrictModeRejectsBOM() {
    let raw = "\u{FEFF}{\"intent\":\"new_content\",\"text\":\"嗨\"}"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受 leading BOM")
    }
}

@Test func envelopeParserStrictAcceptsPureJSON() {
    let raw = "{\"intent\":\"new_content\",\"text\":\"嗨\"}"
    guard case .success(let env) = EnvelopeParser.parse(raw, mode: .strict) else {
        Issue.record("strict 應接受純 JSON"); return
    }
    #expect(env.intent == "new_content")
    #expect(env.text == "嗨")
}

@Test func envelopeParserLenientAcceptsFencedJSON() {
    let raw = "```json\n{\"intent\":\"new_content\",\"text\":\"嗨\"}\n```"
    guard case .success(let env) = EnvelopeParser.parse(raw, mode: .lenient) else {
        Issue.record("lenient 應接受 fenced JSON"); return
    }
    #expect(env.intent == "new_content")
}

@Test func envelopeParserStrictRejectsExtraField() {
    let raw = "{\"intent\":\"new_content\",\"text\":\"嗨\",\"extra\":\"x\"}"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受額外欄位")
    }
}

@Test func envelopeParserStrictRejectsMissingField() {
    let raw = "{\"intent\":\"new_content\"}"   // 缺 text
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受缺欄位")
    }
}

@Test func envelopeParserStrictRejectsZeroWidthEscape() {
    // JSON escape 路徑：intent 中含 U+200B
    let raw = "{\"intent\":\"new_content\\u200B\",\"text\":\"嗨\"}"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受 decoded zero-width")
    }
}

@Test func envelopeParserStrictRejectsBidiEscape() {
    let raw = "{\"intent\":\"new_content\",\"text\":\"嗨\\u202E\"}"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受 decoded bidi control")
    }
}

@Test func envelopeParserStrictRejectsHomoglyphBraces() {
    // 全形花括號｛｝ — 視為 structural homoglyph
    let raw = "｛\"intent\":\"new_content\",\"text\":\"嗨\"｝"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受全形花括號")
    }
}

@Test func envelopeParserStrictRejectsMultipleObjects() {
    let raw = "{\"intent\":\"new_content\",\"text\":\"嗨\"}{\"intent\":\"new_content\",\"text\":\"嗨\"}"
    if case .success = EnvelopeParser.parse(raw, mode: .strict) {
        Issue.record("strict 不該接受多個 JSON 物件")
    }
}

@Test func envelopeParserStrictAcceptsWhitespaceNewline() {
    let raw = "{\n  \"intent\": \"new_content\",\n  \"text\": \"嗨\"\n}"
    guard case .success = EnvelopeParser.parse(raw, mode: .strict) else {
        Issue.record("strict 應接受 JSON whitespace"); return
    }
}

@Test func envelopeParserStrictAcceptsChinesePunctuationInTextValue() {
    // SPEC §3.3 rule 4：structural homoglyph 檢查不得誤殺 text 值內的正常全形標點
    // （M4 風格規則本來就要求中文輸出用全形標點，，：；都是常態）。
    let raw = "{\"intent\":\"new_content\",\"text\":\"你好，世界：測試；完成\"}"
    guard case .success(let env) = EnvelopeParser.parse(raw, mode: .strict) else {
        Issue.record("strict 不該因 text 值內的正常全形標點誤拒"); return
    }
    #expect(env.text == "你好，世界：測試；完成")
}
