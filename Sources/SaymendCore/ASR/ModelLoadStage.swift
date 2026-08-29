/// 本機模型載入的四個階段（issue #17）。
///
/// `allCases` 的順序就是 `WhisperKit.loadModels()` 的實際載入順序
/// （`Core/WhisperKit.swift:358-442`），設定頁直接用它排版就不會與實際順序脫節。
public enum ModelLoadStage: String, CaseIterable, Equatable, Sendable {
    case featureExtractor, textDecoder, audioEncoder, tokenizer

    /// 設定頁顯示名。放在 Core 而不是 UI，是為了讓「階段」這件事只有一份定義。
    public var label: String {
        switch self {
        case .featureExtractor: return "特徵擷取器"
        case .textDecoder:      return "文字解碼器"
        case .audioEncoder:     return "音訊編碼器"
        case .tokenizer:        return "tokenizer"
        }
    }
}

/// 從 WhisperKit 的 log 訊息認出來的載入里程碑（issue #17）。
public enum ModelLoadLogEvent: Equatable, Sendable {
    /// 新的一趟載入開始——進度要從這裡重置。
    case loadBegan
    case stageBegan(ModelLoadStage)
    /// `seconds` 為 nil＝該則訊息本身沒帶耗時（特徵擷取器那一則就沒有）。
    case stageFinished(ModelLoadStage, seconds: Double?)
    case loadFinished(seconds: Double)
}

/// 把 WhisperKit 的 log 字串解析成載入里程碑（issue #17）。
///
/// **為什麼是「觀察」而不是「重寫載入流程」。** 套件也允許 `load: false` 之後自行逐一呼叫
/// 子模型的 `loadModel(at:computeUnits:prewarmMode:)`，那樣拿到的進度更精確；但那等於把
/// `loadModels()` 的內容抄一份，套件升級時會**無聲地**與官方流程分歧。
/// 觀察失準只是少了進度（UI 退回純碼表），重寫失準是載壞模型。
///
/// 訊息來源 `Core/WhisperKit.swift`（套件 pin 在 `exact: "1.0.0"`），行號註在各條比對上。
/// 認不得一律回 nil——升級後字串若改動，這裡靜靜地不再產出事件，載入本身完全不受影響。
///
/// **注意這些訊息是 `Logging.debug` 等級**（只有 :91 與 :441 兩則是 `.info`）。
/// `WhisperKitConfig.logLevel` 若設回 `.info`，`Logging.log` 的守衛
/// `level <= messageLevel` 會把分階段的訊息整批擋掉，本解析器就再也收不到東西。
public enum WhisperLoadLogParser {
    public static func event(from message: String) -> ModelLoadLogEvent? {
        // **規則彼此互斥，順序不影響結果**——變異測試把總結那條真的搬到最後仍全綠。
        // 之所以還是照載入順序排，只是為了讀起來對得上 `loadModels()` 的流程。
        // 真正吃重的是「用完全相等而非前綴」：`Loading models from …`（:369）與
        // `Loading models...`（:91）同前綴，改成 hasPrefix 就會把前者也當成新的一趟開始。
        if message == "Loading models..." { return .loadBegan }                          // :91
        if let s = seconds(after: "Loaded models for whisper size:", in: message) {      // :441
            return .loadFinished(seconds: s)
        }
        if message == "Loading feature extractor" { return .stageBegan(.featureExtractor) }   // :383
        if message == "Loaded feature extractor" {                                            // :389
            return .stageFinished(.featureExtractor, seconds: nil)   // 這一則不帶耗時
        }
        if message == "Loading text decoder" { return .stageBegan(.textDecoder) }             // :393
        if let s = seconds(after: "Loaded text decoder", in: message) {                       // :407
            return .stageFinished(.textDecoder, seconds: s)
        }
        if message == "Loading audio encoder" { return .stageBegan(.audioEncoder) }           // :411
        if let s = seconds(after: "Loaded audio encoder", in: message) {                      // :426
            return .stageFinished(.audioEncoder, seconds: s)
        }
        if message.hasPrefix("Loading tokenizer for") { return .stageBegan(.tokenizer) }      // :459
        if let s = seconds(after: "Loaded tokenizer", in: message) {                          // :484
            return .stageFinished(.tokenizer, seconds: s)
        }
        return nil
    }

    /// 認 `<prefix> … in <數字>s` 這個共同形狀，取出那個數字。
    ///
    /// 用 `.backwards` 找分隔字串：模型名稱本身可能含 " in "（例如 `built-in-v3`），
    /// 從前面找會把名字的一部分當成數字。前綴不符、結尾不是 `s`、或中間不是合法浮點數，一律 nil。
    private static func seconds(after prefix: String, in message: String) -> Double? {
        guard message.hasPrefix(prefix), message.hasSuffix("s") else { return nil }
        let body = message.dropLast()                                   // 去掉結尾的 "s"
        guard let r = body.range(of: " in ", options: .backwards) else { return nil }
        return Double(body[r.upperBound...])
    }
}
