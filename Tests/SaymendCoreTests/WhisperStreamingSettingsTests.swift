import Foundation
import Testing
import WhisperKit
@testable import SaymendCore

private func freshStreamSettings() -> (AppSettings, UserDefaults) {
    let suite = "test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return (AppSettings(defaults: d, secrets: InMemorySecretStore()), d)
}

// MARK: - 套件預設值的單一出處

/// **釘住套件預設值。** `WhisperStreamingOptions` 對兩個解碼門檻以 nil 表示「不覆寫」，
/// 但設定頁需要具體數字才顯示得出「套件預設是多少」，因此我們自己抄了一份常數。
/// 抄來的常數會過期——套件哪天改了預設，設定頁就會對使用者說謊。這條測試讓它當場失敗。
@Test func packageThresholdConstantsMatchWhisperKit() {
    let packageDefaults = DecodingOptions()
    #expect(packageDefaults.logProbThreshold == WhisperStreamingOptions.packageLogProbThreshold)
    #expect(packageDefaults.compressionRatioThreshold == WhisperStreamingOptions.packageCompressionRatioThreshold)
}

/// 串流轉錄器那四個參數的預設寫在它 init 的參數預設值裡，執行期讀不到，
/// 只能以「我們的預設＝當初讀到的值」自證一致。此處釘住我們這一側，
/// 升套件時仍須人工比對 `AudioStreamTranscriber.init`。
@Test func streamingOptionDefaultsAreThePackageOnes() {
    let d = WhisperStreamingOptions.packageDefault
    #expect(d.requiredSegmentsForConfirmation == 2)
    #expect(d.silenceThreshold == 0.3)
    #expect(d.useVAD)
    #expect(d.relativeEnergyWindow == 20)
    #expect(d.compressionCheckWindow == 60)
    #expect(d.logProbThreshold == nil)              // nil＝不覆寫，交套件自己的預設
    #expect(d.compressionRatioThreshold == nil)
}

// MARK: - 設定 → 參數的轉換

@Test func streamingOptionsFallBackToPackageDefaultsWhenUnset() {
    let (s, _) = freshStreamSettings()
    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == 2)
    #expect(o.silenceThreshold == 0.3)
    #expect(o.useVAD)
    #expect(o.relativeEnergyWindow == 20)
    #expect(o.compressionCheckWindow == 60)
    #expect(o.logProbThreshold == WhisperStreamingOptions.packageLogProbThreshold)
    #expect(o.compressionRatioThreshold == WhisperStreamingOptions.packageCompressionRatioThreshold)
}

@Test func streamingOptionsCarryUserValues() {
    let (s, _) = freshStreamSettings()
    s.streamRequiredSegments = 4
    s.streamSilenceThreshold = 0.55
    s.streamUseVAD = false
    s.streamRelativeEnergyWindow = 8
    s.streamCompressionCheckWindow = 120
    s.streamLogProbThreshold = -2.5
    s.streamCompressionRatioThreshold = 1.8

    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == 4)
    #expect(o.silenceThreshold == 0.55)
    #expect(!o.useVAD)
    #expect(o.relativeEnergyWindow == 8)
    #expect(o.compressionCheckWindow == 120)
    #expect(o.logProbThreshold == -2.5)
    #expect(o.compressionRatioThreshold == 1.8)
}

@Test func streamingSettingsPersistAcrossInstances() {
    let suite = "test-\(UUID().uuidString)"
    let s = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    s.streamRequiredSegments = 5
    s.streamUseVAD = false
    s.streamLogProbThreshold = -3.0
    let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!, secrets: InMemorySecretStore())
    #expect(reloaded.streamRequiredSegments == 5)
    #expect(!reloaded.streamUseVAD)
    #expect(reloaded.streamLogProbThreshold == -3.0)
}

// MARK: - 讀取防線（比照既有逾時設定：超界回落預設，不是夾到邊界值）

/// 存進去的值超出合理範圍＝設定損毀（手改 plist、舊版遺留、寫入時的錯誤）。
/// 回落套件預設而非夾到邊界：邊界值是使用者從未選過的值，預設才是已知良好的那個。
@Test func streamingOptionsRejectOutOfRangeStoredValues() {
    let (s, d) = freshStreamSettings()
    d.set(0, forKey: "whisperStreamRequiredSegments")          // < 1
    d.set(999, forKey: "whisperStreamEnergyWindow")            // > 200
    d.set(-0.5, forKey: "whisperStreamSilenceThreshold")       // < 0
    d.set(0, forKey: "whisperStreamCompressionCheckWindow")    // < 1
    d.set(1.0, forKey: "whisperStreamLogProbThreshold")        // > 0
    d.set(0.5, forKey: "whisperStreamCompressionRatioThreshold") // < 1

    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == 2)
    #expect(o.relativeEnergyWindow == 20)
    #expect(o.silenceThreshold == 0.3)
    #expect(o.compressionCheckWindow == 60)
    #expect(o.logProbThreshold == WhisperStreamingOptions.packageLogProbThreshold)
    #expect(o.compressionRatioThreshold == WhisperStreamingOptions.packageCompressionRatioThreshold)
}

/// NaN／Inf 過得了範圍比較（NaN 的所有比較都是 false，`contains` 亦然）但會毒害下游：
/// NaN 靜音門檻讓 `> threshold` 恆為假、VAD 從此判定「永遠沒人講話」。
@Test func streamingOptionsRejectNonFiniteStoredValues() {
    let (s, d) = freshStreamSettings()
    d.set(Double.nan, forKey: "whisperStreamSilenceThreshold")
    d.set(Double.infinity, forKey: "whisperStreamLogProbThreshold")
    d.set(-Double.infinity, forKey: "whisperStreamCompressionRatioThreshold")

    let o = s.whisperStreamingOptions()
    #expect(o.silenceThreshold == 0.3)
    #expect(o.logProbThreshold == WhisperStreamingOptions.packageLogProbThreshold)
    #expect(o.compressionRatioThreshold == WhisperStreamingOptions.packageCompressionRatioThreshold)
}

/// 型別不符（舊版寫成字串、手改 plist）不得讓整個 App 拿到垃圾參數
@Test func streamingOptionsRejectWrongTypedStoredValues() {
    let (s, d) = freshStreamSettings()
    d.set("很多", forKey: "whisperStreamRequiredSegments")
    d.set("吵", forKey: "whisperStreamSilenceThreshold")

    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == 2)
    #expect(o.silenceThreshold == 0.3)
}

/// 邊界值本身必須是合法的——防線寫成開區間會把使用者能從 UI 選到的極值當成損毀值丟掉
@Test func streamingOptionsAcceptRangeBoundaries() {
    let (s, _) = freshStreamSettings()
    s.streamRequiredSegments = WhisperStreamingOptions.requiredSegmentsRange.lowerBound
    s.streamSilenceThreshold = Double(WhisperStreamingOptions.silenceThresholdRange.upperBound)
    s.streamRelativeEnergyWindow = WhisperStreamingOptions.relativeEnergyWindowRange.upperBound
    s.streamLogProbThreshold = Double(WhisperStreamingOptions.logProbThresholdRange.lowerBound)

    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == WhisperStreamingOptions.requiredSegmentsRange.lowerBound)
    #expect(o.silenceThreshold == WhisperStreamingOptions.silenceThresholdRange.upperBound)
    #expect(o.relativeEnergyWindow == WhisperStreamingOptions.relativeEnergyWindowRange.upperBound)
    #expect(o.logProbThreshold == WhisperStreamingOptions.logProbThresholdRange.lowerBound)
}

// MARK: - 換模型後參數仍然有效

/// 參數與模型是兩件事：換模型不該把調好的串流參數洗掉，否則每換一次模型就要重調一輪。
@Test func streamingOptionsSurviveModelChange() {
    let (s, _) = freshStreamSettings()
    s.streamRequiredSegments = 6
    s.streamSilenceThreshold = 0.45
    s.whisperLocalModelPath = URL(filePath: "/models/large-v3-turbo")
    s.whisperLocalModelPath = URL(filePath: "/models/small")

    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == 6)
    #expect(o.silenceThreshold == 0.45)
}

/// 「還原預設」＝把 key 移除，回到與從未調過完全相同的狀態（不是寫入一份預設值的複本）
@Test func clearingStreamingSettingsRestoresPackageDefaults() {
    let (s, _) = freshStreamSettings()
    s.streamRequiredSegments = 7
    s.streamUseVAD = false
    s.streamCompressionRatioThreshold = 5.0
    s.resetStreamingOptions()

    let o = s.whisperStreamingOptions()
    #expect(o.requiredSegmentsForConfirmation == 2)
    #expect(o.useVAD)
    #expect(o.compressionRatioThreshold == WhisperStreamingOptions.packageCompressionRatioThreshold)
}
