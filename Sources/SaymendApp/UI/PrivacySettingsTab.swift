import CoreGraphics
import SwiftUI
import SaymendCore

/// 隱私透明（規格 §4.9）：明列「哪些內容會送到哪個 LLM 端點」。
struct PrivacySettingsTab: View {
    let settings: AppSettings
    @State private var ocrEnabled: Bool
    /// 引擎在「一般」分頁切換，故本分頁的快照須於出現時重讀（spec §6.1）
    @State private var asrEngineKind: ASREngineKind

    init(settings: AppSettings) {
        self.settings = settings
        _ocrEnabled = State(initialValue: settings.ocrContextEnabled)
        _asrEngineKind = State(initialValue: settings.asrEngineKind)
    }

    var body: some View {
        Form {
            Section("資料流向") {
                switch asrEngineKind {
                case .speechAnalyzer:
                    LabeledContent("語音辨識", value: "本機（Apple SpeechAnalyzer），不出機器")
                case .whisperRemote:
                    LabeledContent("語音辨識",
                                   value: "遠端（Whisper 端點 \(settings.whisperBaseURLString)）——聽寫音訊會上傳")
                    Text("音訊含聲紋與環境聲，敏感度高於文字。請確認端點可信（自架端點的音訊不出區網）。")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("LLM 端點", value: settings.llmBaseURLString)
                LabeledContent("送出的內容", value: "轉錄文字、session 全文／選取文字、游標前後文、OCR 螢幕參考、詞彙表、前景 App 名稱、你的自訂規則與 per-app 追加規則")
                Text("使用本地端點（Ollama／LM Studio／MLX）時，以上內容皆不出機器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("錄音") {
                LabeledContent("錄音檔", value: "不儲存（預設且目前無此功能）")
            }
            Section("OCR 螢幕語境備援") {
                Toggle("啟用 OCR 螢幕語境備援", isOn: $ocrEnabled)
                LabeledContent("螢幕錄製權限",
                               value: CGPreflightScreenCaptureAccess() ? "已授權" : "未授權（需於系統設定開啟後才能實際截圖）")
                if ocrEnabled, !CGPreflightScreenCaptureAccess() {
                    Text("已開啟，但尚未取得螢幕錄製權限——目前不會截圖。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("請求螢幕錄製權限…") {
                        // 顯式 opt-in 才請求（原「只查不問」是自動備援時代的設計；改成使用者開關後，
                        // 明確開啟即應可授權）。首次會跳系統對話框並把本 App 加入螢幕錄製清單；
                        // 授權後需重啟 App 權限才對 ScreenCaptureKit 生效。
                        _ = CGRequestScreenCaptureAccess()
                    }
                    Text("授權後請重新啟動 Saymend，權限才會生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("預設關閉。開啟後，僅在輔助使用讀不到游標前後文、且非安全欄位時，才截取聚焦欄位附近的小區域畫面。OCR 由 Vision 於本機執行；截圖不落地、辨識文字僅作當次 LLM 語境、不留歷史。截圖範圍是螢幕可見畫面——若鄰近有其他 App 視窗露出，其可見文字可能一併入鏡。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("密碼欄位") {
                Text("安全輸入欄位一律拒絕聽寫：不錄音、不送 LLM、不留歷史、不觸發 OCR 與剪貼簿備援。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: ocrEnabled) { _, v in settings.ocrContextEnabled = v }
        .onAppear { asrEngineKind = settings.asrEngineKind }
    }
}
