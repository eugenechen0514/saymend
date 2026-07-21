import Testing
@testable import SaymendCore

// M5 Task 7 起 strict 是 production 預設；這個檔案原本測的是寬容行為（fenced JSON、
// leading prose、缺欄位），全部改走 .lenient（診斷用途），驗證舊行為仍受保留。
// strict 的拒收行為改由 EnvelopeParserStrictTests.swift 驗證。

private func lenientValue(_ raw: String) -> LLMEnvelope? {
    guard case .success(let env) = EnvelopeParser.parse(raw, mode: .lenient) else { return nil }
    return env
}

@Test func parsesPlainJSON() {
    let r = lenientValue(#"{"intent":"new_content","text":"你好"}"#)
    #expect(r == LLMEnvelope(intent: "new_content", text: "你好"))
}

@Test func parsesFencedJSON() {
    let raw = """
    ```json
    {"intent":"new_content","text":"哈囉 world"}
    ```
    """
    #expect(lenientValue(raw)?.text == "哈囉 world")
}

@Test func parsesJSONWithLeadingProse() {
    let raw = #"好的，以下是結果：{"intent":"new_content","text":"ok"}"#
    #expect(lenientValue(raw)?.text == "ok")
}

@Test func rejectsGarbageButToleratesMissingFields() {
    #expect(lenientValue("完全不是 JSON") == nil)
    #expect(lenientValue("") == nil)
    // 寬容解碼：長尾模型常省略空欄位——undo 缺 text 補空字串，缺 intent 依「模糊→new_content」補預設
    #expect(lenientValue(#"{"intent":"undo"}"#) == LLMEnvelope(intent: "undo", text: ""))
    #expect(lenientValue(#"{"intent":"new_content"}"#) == LLMEnvelope(intent: "new_content", text: ""))
    #expect(lenientValue(#"{"text":"你好"}"#) == LLMEnvelope(intent: "new_content", text: "你好"))
}
