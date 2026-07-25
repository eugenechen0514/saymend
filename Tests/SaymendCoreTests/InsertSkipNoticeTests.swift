import Testing
@testable import SaymendCore

// 文案唯一定義點，比照 degradedReason：以全等斷言鎖定字串，避免同一句話在多處各寫一份而漂移。

@Test func insertSkipNoticeSpellsOutEachCause() {
    #expect(insertSkipNotice(.frozen) == "未潤飾（已停止改寫）")
    #expect(insertSkipNotice(.tailAdvanced) == "未潤飾（文字位置已變動）")
    #expect(insertSkipNotice(.writeFailed) == "未潤飾（寫入失敗）")
    #expect(insertSkipNotice(.unknown) == "未潤飾（未知錯誤）")
}

@Test func insertSkipNoticeCausesAreAllDistinct() {
    // 四義同形正是本票要修的病：任兩個成因的文案都不得相同
    let all: [InsertSkipCause] = [.frozen, .tailAdvanced, .writeFailed, .unknown]
    let notices = Set(all.map(insertSkipNotice))
    #expect(notices.count == all.count)
}

@Test func insertSkipNoticeKeepsTheSharedPrefix() {
    // 使用者已習慣「未潤飾」這個詞；加原因是補充，不是換掉
    for cause in [InsertSkipCause.frozen, .tailAdvanced, .writeFailed, .unknown] {
        #expect(insertSkipNotice(cause).hasPrefix("未潤飾（"))
        #expect(insertSkipNotice(cause).hasSuffix("）"))
    }
}
