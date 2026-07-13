import Testing
@testable import SpeeckinkCore

@Test func parsesPlainJSON() {
    let r = EnvelopeParser.parse(#"{"intent":"new_content","text":"你好"}"#)
    #expect(r == LLMEnvelope(intent: "new_content", text: "你好"))
}

@Test func parsesFencedJSON() {
    let raw = """
    ```json
    {"intent":"new_content","text":"哈囉 world"}
    ```
    """
    #expect(EnvelopeParser.parse(raw)?.text == "哈囉 world")
}

@Test func parsesJSONWithLeadingProse() {
    let raw = #"好的，以下是結果：{"intent":"new_content","text":"ok"}"#
    #expect(EnvelopeParser.parse(raw)?.text == "ok")
}

@Test func rejectsGarbageButToleratesMissingFields() {
    #expect(EnvelopeParser.parse("完全不是 JSON") == nil)
    #expect(EnvelopeParser.parse("") == nil)
    // 寬容解碼：長尾模型常省略空欄位——undo 缺 text 補空字串，缺 intent 依「模糊→new_content」補預設
    #expect(EnvelopeParser.parse(#"{"intent":"undo"}"#) == LLMEnvelope(intent: "undo", text: ""))
    #expect(EnvelopeParser.parse(#"{"intent":"new_content"}"#) == LLMEnvelope(intent: "new_content", text: ""))
    #expect(EnvelopeParser.parse(#"{"text":"你好"}"#) == LLMEnvelope(intent: "new_content", text: "你好"))
}
