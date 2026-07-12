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

@Test func rejectsGarbageAndMissingFields() {
    #expect(EnvelopeParser.parse("完全不是 JSON") == nil)
    #expect(EnvelopeParser.parse(#"{"intent":"new_content"}"#) == nil)
    #expect(EnvelopeParser.parse("") == nil)
}
