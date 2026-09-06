import ApplicationServices
import Testing
import SaymendCore
@testable import SaymendApp

/// issue #37 的連帶修正：把 AX 訊息 timeout 收到 0.2 秒之後，`AXError.cannotComplete`
/// 的含意從「目標 App 死了」變成「目標 App 只是慢」，於是全 repo 原本一律把 `!= .success`
/// 壓成單一分支的寫法開始有實際危害。這裡釘住的是**逾時不得被當成語意答案**。
///
/// header 依據：`AXError.h` 對 `kAXErrorCannotComplete` 的定義是
/// 「messaging failed in some way or because the application with which the function is
///  communicating is busy or unresponsive」。
@Suite struct AXTimeoutSemanticsTests {

    // MARK: - §5.3 密碼欄位偵測（fail closed）

    /// 問到了：subrole 就是密碼欄。
    @Test func secureSubroleIsSecure() {
        #expect(AXFieldAccess.secureVerdict(error: .success,
                                            subrole: kAXSecureTextFieldSubrole as String) == .secure)
    }

    /// 問到了：不是密碼欄。
    @Test func ordinarySubroleIsNotSecure() {
        #expect(AXFieldAccess.secureVerdict(error: .success, subrole: "AXStandardWindow") == .notSecure)
        #expect(AXFieldAccess.secureVerdict(error: .success, subrole: nil) == .notSecure)
    }

    /// 「元素沒有 subrole 這個屬性」是問到了的答案，維持寬鬆——大量非 AX-rich 欄位落在這裡，
    /// 一律 fail closed 會讓聽寫在這些 App 內整個失效（issue #21 的既有契約）。
    @Test func attributeMissingStaysLenient() {
        for error: AXError in [.attributeUnsupported, .noValue, .notImplemented, .invalidUIElement] {
            #expect(AXFieldAccess.secureVerdict(error: error, subrole: nil) == .notSecure,
                    "AXError \(error.rawValue) 應維持既有寬鬆行為")
        }
    }

    /// 逾時**不是**「不是密碼欄」的答案。
    @Test func timeoutIsUnknownNotNotSecure() {
        #expect(AXFieldAccess.secureVerdict(error: .cannotComplete, subrole: nil) == .unknown)
    }

    /// 一路逾時：重試一次，仍問不出來就 fail closed（當作密碼欄）——
    /// 這是規格 §5.3 的總閘門，誤判成 false 會在密碼欄開 session、把唸出的密碼送上雲端。
    @Test func snapshotFailsClosedWhenSubroleKeepsTimingOut() {
        let registry = AXFieldRegistry()
        var reads = 0
        let reader = AXFieldReader(registry: registry, readSubrole: { _ in
            reads += 1
            return (.cannotComplete, nil)
        })
        let context = reader.snapshot(of: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        #expect(context.isSecure)
        #expect(context.fieldIdentity == nil, "fail closed 時不得登記 identity（密碼欄不 begin，登記了沒人歸還）")
        #expect(reads == 2, "逾時要重試一次才放棄")
    }

    /// 重試救得回來：第二次問到了、不是密碼欄，就照常走一般欄位路徑。
    @Test func snapshotProceedsWhenRetryAnswers() {
        let registry = AXFieldRegistry()
        var reads = 0
        let reader = AXFieldReader(registry: registry, readSubrole: { _ in
            reads += 1
            return reads == 1 ? (.cannotComplete, nil) : (.success, "AXStandardWindow")
        })
        let context = reader.snapshot(of: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        #expect(!context.isSecure)
        #expect(reads == 2)
        reader.releaseFieldIdentity(context.fieldIdentity)
    }

    /// 第一次就問到是密碼欄：不重試、直接擋。
    @Test func snapshotStopsAtSecureWithoutRetrying() {
        let registry = AXFieldRegistry()
        var reads = 0
        let reader = AXFieldReader(registry: registry, readSubrole: { _ in
            reads += 1
            return (.success, kAXSecureTextFieldSubrole as String)
        })
        let context = reader.snapshot(of: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        #expect(context.isSecure)
        #expect(reads == 1)
    }

    // MARK: - overlay 能力探測（逾時不得被持久化）

    /// 問到了、清單裡有 BoundsForRange＝支援。
    @Test @MainActor func capabilityTrueWhenAttributeListed() {
        let names = [kAXBoundsForRangeParameterizedAttribute as String, "AXFoo"]
        #expect(FeedbackCoordinator.boundsForRangeCapability(error: .success, names: names) == true)
    }

    /// 問到了、清單裡沒有＝真的不支援，這個 false 才可以被寫進持久 profile。
    @Test @MainActor func capabilityFalseWhenAttributeAbsent() {
        #expect(FeedbackCoordinator.boundsForRangeCapability(error: .success, names: ["AXFoo"]) == false)
        #expect(FeedbackCoordinator.boundsForRangeCapability(error: .attributeUnsupported, names: nil) == false)
    }

    /// 逾時＝nil（未知）。呼叫端據此既不入 session 快取也不回填持久 profile——
    /// 一次 200ms 逾時若被寫成 false，就會跨重啟永久把該 App 的 overlay 降級成 HUD diff，
    /// 且下次進同一個 bundle 會短路不再探測，App 內沒有任何重新探測的路徑。
    @Test @MainActor func capabilityUnknownOnTimeout() {
        #expect(FeedbackCoordinator.boundsForRangeCapability(error: .cannotComplete, names: nil) == nil)
    }
}
