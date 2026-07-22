import Foundation

/// degraded reason 的唯一定義點（M7 spec §3.3）：IntentService 與 ProviderTester 共用，
/// 語彙不漂移。字串逐字對照 spec 分流表，測試以全等斷言鎖定。
public func degradedReason(for error: any Error, timeout: TimeInterval) -> String {
    switch error {
    case LLMError.timedOut:
        return "逾時 \(String(format: "%g", timeout)) 秒"   // %g：3.0→3、2.5→2.5
    case LLMError.badStatus(let code):
        return "HTTP \(code)"
    case LLMError.emptyResponse:
        return "回應內容為空"
    case ClaudeCLIError.cliNotFound:
        return "找不到 claude CLI"
    case ClaudeCLIError.processFailed(let code):
        return "CLI 結束碼 \(code)"
    case ClaudeCLIError.spawnFailed:
        return "CLI 啟動失敗"
    default:
        return "無法連線"                                    // URLError 連線類與未知錯誤的合流
    }
}
