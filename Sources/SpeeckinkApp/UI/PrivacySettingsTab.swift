import CoreGraphics
import SwiftUI
import SpeeckinkCore

/// 隱私透明（規格 §4.9）：明列「哪些內容會送到哪個 LLM 端點」。
struct PrivacySettingsTab: View {
    let settings: AppSettings

    var body: some View {
        Form {
            Section("資料流向") {
                LabeledContent("語音辨識", value: "本機（Apple SpeechAnalyzer），不出機器")
                LabeledContent("LLM 端點", value: settings.llmBaseURLString)
                LabeledContent("送出的內容", value: "轉錄文字、session 全文／選取文字、游標前後文、OCR 螢幕參考、詞彙表、前景 App 名稱")
                Text("使用本地端點（Ollama／LM Studio／MLX）時，以上內容皆不出機器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("錄音") {
                LabeledContent("錄音檔", value: "不儲存（預設且目前無此功能）")
            }
            Section("OCR 備援") {
                LabeledContent("螢幕錄製權限",
                               value: CGPreflightScreenCaptureAccess() ? "已授權（AX 讀不到欄位時啟用小區域截圖）" : "未授權（OCR 備援停用；選配，可於系統設定開啟）")
                Text("OCR 由 Vision 於本機執行；截圖不落地、辨識文字僅作當次 LLM 語境。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("密碼欄位") {
                Text("安全輸入欄位一律拒絕聽寫：不錄音、不送 LLM、不留歷史、不觸發 OCR 與剪貼簿備援。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
