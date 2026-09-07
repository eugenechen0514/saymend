import ApplicationServices
import Testing
@testable import SaymendApp

/// issue #37 調查發現的獨立缺陷：全 repo 沒有設過 `AXUIElementSetMessagingTimeout`，
/// 所有 AX 呼叫吃系統預設 timeout（最壞秒級）。AX 呼叫是同步阻塞的跨行程 IPC，
/// 而 main thread 上有 10Hz overlay 輪詢與每句上屏的 AX 讀寫——目標 App 卡住時
/// 會連帶拖住掛在 main run loop 的熱鍵事件 tap，使用者連 Esc 中止都按不動。
///
/// 這個改動只有一行 C API 呼叫，可測的東西有限；這裡釘住的是**送進 C API 的參數合法且正確**、
/// 以及**失敗不會被吞掉當成成功**。至於「App 啟動時真的呼叫了它」則無 seam 可測（見 PR 說明）。
@Suite struct AXMessagingTimeoutTests {

    /// 走真正的 `AXUIElementSetMessagingTimeout` 與真正的 system-wide element、用出貨的預設值。
    /// 回 `.success` 才代表我們送出的是合法參數（header：timeout 必須為正數、element 必須有效）。
    /// 設 timeout 是行程內的本機設定，不需要輔助使用權限，所以在測試行程裡也會成功。
    ///
    /// **這是唯一會真的動到測試行程全域狀態的測試**：對 system-wide element 設 timeout
    /// 會套用到本行程之後送出的所有 AX 訊息，也就是同一個 process 裡後面跑的每一條測試
    /// （AXFieldGateTests／AXTimeoutSemanticsTests 都會對真元素發 AX 訊息）。故必須還原。
    ///
    /// 還原方式的依據是 `AXUIElement.h` 對 `AXUIElementSetMessagingTimeout` 的說明：
    /// 「Setting `timeoutInSeconds` to 0 for the system-wide accessibility object resets the
    ///  global timeout to its default value」——**沒有 getter**，拿不到原值，官方指定的重置手段就是傳 0。
    /// （同一段 header 又說 illegal argument「timeout values must be positive」，兩句話看似衝突；
    ///  實測對 system-wide element 傳 0 回 `.success`，即下面 defer 裡那條斷言。）
    /// 這裡直接呼叫 C API 而不走 `AXMessagingTimeout.applyGlobally`：後者刻意把 0 擋在門外
    /// （production 不該把全域 timeout 重置掉），重置是測試專用的收尾動作。
    @Test func productionDefaultsAreAcceptedByTheRealAXAPI() {
        defer {
            #expect(AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0) == .success,
                    "傳 0 給 system-wide element ＝ 重置回系統預設，必須成功，否則後續測試整批吃 0.2s timeout")
        }
        #expect(AXMessagingTimeout.applyGlobally() == .success)
    }

    /// 出貨預設值必須是 0.2 秒，且只對 system-wide element 設一次
    /// （header：傳 system-wide object 才會套用到本行程送出的所有訊息；傳別的元素只影響那顆元素）。
    @Test func appliesPointTwoSecondsToTheSystemWideElementExactlyOnce() {
        var captured: [(element: AXUIElement, seconds: Float)] = []
        // element 沒有注入點：實作直接呼叫 AXUIElementCreateSystemWide，所以這條斷言驗的是
        // production 真正送出去的那顆元素（實測：把它換成 AXUIElementCreateApplication 的 mutation
        // 會被下面的 CFEqual 殺掉——那正是 header 說的「設在別的元素上只影響那顆元素」的語意錯誤）。
        _ = AXMessagingTimeout.applyGlobally(set: { element, seconds in
            captured.append((element, seconds))
            return .success
        })
        #expect(captured.count == 1)
        #expect(captured.first?.seconds == 0.2)
        #expect(captured.first.map { CFEqual($0.element, AXUIElementCreateSystemWide()) } == true)
    }

    /// 非正數（含 0）是 header 明列的 illegal argument；0 對 system-wide 更是「重置回系統預設」，
    /// 恰好是這個 PR 要避免的狀態。在送進 C API 之前就擋下並回報錯誤碼。
    @Test func rejectsNonPositiveTimeoutWithoutCallingTheAPI() {
        for bad: Float in [0, -1] {
            var calls = 0
            let result = AXMessagingTimeout.applyGlobally(seconds: bad,
                                                          set: { _, _ in
                                                              calls += 1
                                                              return .success
                                                          })
            #expect(result == .illegalArgument, "seconds=\(bad) 必須被擋下")
            #expect(calls == 0, "seconds=\(bad) 不該送進 AXUIElementSetMessagingTimeout")
        }
    }

    /// 失敗要原封不動回傳錯誤碼——不 crash，也不靜默假裝成功。
    @Test func propagatesFailureInsteadOfPretendingSuccess() {
        let result = AXMessagingTimeout.applyGlobally(set: { _, _ in .invalidUIElement })
        #expect(result == .invalidUIElement)
    }
}
