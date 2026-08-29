import Testing
@testable import SaymendCore

@Suite struct WhisperLoadLogParserTests {
    /// 字串一字不差取自套件 `Core/WhisperKit.swift`（pin 在 `exact: "1.0.0"`），
    /// 行號寫在這裡是為了升級套件時對照得到：:91 :383 :389 :393 :407 :411 :426 :441 :459 :484。
    @Test func parsesEveryLoadMilestone() {
        let p = WhisperLoadLogParser.self
        #expect(p.event(from: "Loading models...") == .loadBegan)
        #expect(p.event(from: "Loading feature extractor") == .stageBegan(.featureExtractor))
        #expect(p.event(from: "Loaded feature extractor") == .stageFinished(.featureExtractor, seconds: nil))
        #expect(p.event(from: "Loading text decoder") == .stageBegan(.textDecoder))
        #expect(p.event(from: "Loaded text decoder in 104.21s") == .stageFinished(.textDecoder, seconds: 104.21))
        #expect(p.event(from: "Loading audio encoder") == .stageBegan(.audioEncoder))
        #expect(p.event(from: "Loaded audio encoder in 526.64s") == .stageFinished(.audioEncoder, seconds: 526.64))
        #expect(p.event(from: "Loading tokenizer for large-v3") == .stageBegan(.tokenizer))
        #expect(p.event(from: "Loaded tokenizer in 0.43s") == .stageFinished(.tokenizer, seconds: 0.43))
        #expect(p.event(from: "Loaded models for whisper size: large-v3 in 631.34s")
                == .loadFinished(seconds: 631.34))
    }

    /// 總結那一則（`Loaded models for whisper size: …`）不得被任何階段規則接走。
    ///
    /// **誠實說明**：目前的實作靠「各規則前綴互不重疊」達成，不是靠比對順序——
    /// 變異測試把這條規則搬到所有階段規則之後仍全綠。本測試擋的是**未來**有人
    /// 把某條階段規則的前綴放寬（例如 `Loaded model` 之類）而把總結吃掉。
    @Test func totalIsNotMistakenForAStage() {
        #expect(WhisperLoadLogParser.event(from: "Loaded models for whisper size: tiny in 1.0s")
                == .loadFinished(seconds: 1.0))
    }

    /// `Loading models from …`（:369）緊接在 `Loading models...`（:91）之後印出，兩者同前綴。
    /// 把它也當成「新的一趟開始」會讓進度在剛起步時平白重置一次。
    @Test func loadingModelsFromIsNotLoadBegan() {
        #expect(WhisperLoadLogParser.event(from: "Loading models from /m with prewarmMode: false") == nil)
    }

    /// 耗時要取**最後**那個 " in "，不是第一個。
    ///
    /// **輸入是合成的**：真實的 `modelVariant`（large-v3、small…）不含空格，
    /// 所以目前沒有任何真實訊息分得出正著找與倒著找。保留倒著找是因為這個形狀
    /// （`… in <數字>s`）本來就該從尾端認，而這條測試把那個選擇釘住——
    /// 改成正著找會讓它轉紅，不會無聲地留在程式碼裡。
    @Test func secondsComeFromTheLastInSeparator() {
        #expect(WhisperLoadLogParser.event(from: "Loaded models for whisper size: a in b in 2.5s")
                == .loadFinished(seconds: 2.5))
    }

    /// 認不得就回 nil，不當機也不亂猜——套件升級改了字串時，要「退化成純碼表」而不是壞掉。
    /// `Loaded text decoder in xs` 是關鍵案例：前綴與結尾都對，只有數字不是數字。
    @Test func unknownMessagesAreIgnored() {
        for m in ["", "Running on Mac", "Loaded", "in 3.00s",
                  "Loaded text decoder in xs", "Loaded text decoder in 104.21"] {
            #expect(WhisperLoadLogParser.event(from: m) == nil, "不該解析出東西：\(m)")
        }
    }

    /// `allCases` 的順序就是 UI 排版的順序，也就是 `loadModels()` 的實際載入順序
    /// （`Core/WhisperKit.swift:358-442`）。順序寫錯不會有任何編譯或執行期徵兆。
    @Test func stagesAreDeclaredInLoadOrder() {
        #expect(ModelLoadStage.allCases == [.featureExtractor, .textDecoder, .audioEncoder, .tokenizer])
    }
}
