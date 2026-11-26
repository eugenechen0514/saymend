# Saymend

[English](README.md) | 繁體中文

> *Say it. Consider it mended.*

macOS 語音輸入工具：說完即成稿，改稿用嘴不用滑鼠（M1 為核心聽寫；口頭修正見規格 M2）。

## 需求
- macOS 26+（SpeechAnalyzer）
- Xcode 26 toolchain
- 語音辨識引擎（設定頁三選一，預設「系統內建」）：
  - 系統內建（Apple SpeechAnalyzer）：不需另外設定；該語系的辨識模型由系統管理，首次使用時自動下載。
  - 本機 WhisperKit（離線）：磁碟上的 WhisperKit CoreML 模型資料夾（預設掃描 `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`，也可在設定頁指定其他資料夾）。本機沒有該模型的 tokenizer 快取時，首次使用會向 Hugging Face 取一次。
  - Whisper 遠端：一個 OpenAI `audio/transcriptions` 相容端點（base URL 必填，預設模型 `whisper-1`；API key 與 LLM 的分開存放）。單段錄音上限 10 分鐘。
- 語言模型（選配，用於潤飾、口頭修正與改寫選取；設定頁二選一，預設 OpenAI-compatible）。沒有可用的語言模型時聽寫照常，只是一律保留原始轉錄，HUD 提示「未潤飾（原因）」：
  - OpenAI-compatible 端點（`chat/completions`）：雲端，或本地 Ollama／LM Studio；本機端點可不填 API key。
  - Claude CLI：本機已安裝並登入的 Claude Code `claude` 指令（2.1.216 以上），沿用 Claude Code 的登入、不需要 API key。自動在 `~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 等常見位置尋找，也可在設定頁指定路徑。

## 建置與執行
    ./Scripts/make-app.sh
    open build/Saymend.app

首次啟動請允許：輔助使用、麥克風、語音辨識。打包會以本機的 Apple Development 憑證簽章——
簽章身分穩定，故重新建置後既有的輔助使用授權會保留（找不到 Apple Development 憑證時才退回 ad-hoc 簽章；ad-hoc 每次重簽都會讓授權失效，需要重新勾選）。
打包也會把 `saymend` CLI 放進 `Saymend.app/Contents/Helpers/`，並建立 `~/.local/bin/saymend` symlink（設 `SAYMEND_SKIP_CLI_LINK=1` 可略過；用途見下方「搭配 Claude Code」）。

## 使用
- 按住「右 Cmd」說話，放開即潤飾上屏；短按切換鎖定聽寫，再短按結束。
- 聽寫中按 Esc 取消目前段落。
- 口頭修正（M2）：說完一句後 8 秒內（HUD 顯示「可修正」），直接按住熱鍵說「欸前面星期二改成星期三」這類指令，文字原地更新；說「復原上一步」或點 HUD 的「復原」可回上一版。
- 聽寫中手動打字或點擊滑鼠會「凍結」本段（不再自動改寫）；密碼欄位一律拒絕聽寫——聽寫途中焦點切進密碼欄位，本段會**當場停止**，該句不上屏、不進剪貼簿、也不送雲端潤飾。
- **選取即目標（M3）**：選取欄位文字後按住熱鍵說指令（「改正式一點」「翻成英文」）＝原地改寫選取；說新內容＝取代選取。替換後可繼續口頭修正與復原。替換當下無法用 AX 確認選取位置的 App（焦點已跑、或不支援 AX 範圍讀寫）不動欄位，結果進剪貼簿並提示。
- **視覺回饋（M3）**：語音掌控中的文字帶細底線；每次替換閃現高亮。App 不支援座標查詢時，HUD 以刪除線／底線 diff 呈現最近異動。放棄替換選取（選取已變、無法用 AX 確認）時欄位沒有動，只有 HUD 提示、沒有高亮。
- **詞彙表（M4）**：自訂詞彙＋常見誤轉寫，同時餵 LLM 校正與 ASR 語音偏置；JSON 匯入匯出。
- **App 感知（M4）**：per-app profile——追加 prompt、固定語系、能力快取持久化、Cmd+C 選取備援白名單。內建 Slack／Chrome／VS Code／Terminal 等預設。
- **自訂 Prompt 與風格（M4）**：全域自訂 system prompt 與輸出風格覆寫；核心規則置頂不可覆蓋。
- **OCR 螢幕語境（M4）**：小區域截圖＋Vision 本地辨識入 LLM 語境（需螢幕錄製權限，選配）。設定可選「關閉」「僅備援」（AX 讀不到欄位時才用）或「一律附加」（AX 讀得到也同時附上）。
- **聽寫歷史（M4）**：SQLite 記錄 session／轉錄／結果，設定頁回查複製；可關閉、可設保留天數。
- **可選核心模式（M5）**：4 內建模式（純聽寫整理／逐字稿／可回答・助理／精簡+正式改寫）＋自訂模式 CRUD；選單列快速切換、per-app 綁定、全域預設。解析優先序：本次聽寫 > per-app > 全域 > 內建。

## 搭配 Claude Code：語音迴圈（saymend-voice）

Saymend 可以當 Claude Code 的語音輸入：搭配 macOS 的 `say` 朗讀回覆，組成「說話 → 送進 Claude Code → 回覆唸出來」的迴圈，靠的是 Saymend 的本機控制介面與 `saymend` CLI（契約見 [docs/control-interface_tw.md](docs/control-interface_tw.md)）。Claude Code 那一側的 mod、安裝方式與完整說明請見 [`saymend-voice`](https://github.com/eugenechen0514/claude-code-mods/tree/main/mods/saymend-voice)（該 repository 目前是 private，只有被邀請的人能存取）。

## 核心模式與安全邊界

Saymend 的 JSON 輸出格式、意圖分類（new_content／edit_command／undo）與「上下文資料僅供語境、不可夾帶指令」由程式碼強制：不合約的回應會在解析與意圖守衛層被拒收並降級，不會寫入你的欄位。

核心模式可調整回答、逐字或改寫策略，但無法修改上述機器契約。

**已知限制**：模型是否忠實遵從契約字面屬 best-effort，無法形式證明。Saymend 保證的是「不合約的回應不會取得寫入資格」，不是「模型永不被誘導」。

## 疑難排解

- **聽寫常被誤判成「欄位已切換」而不上屏**：每次上屏前會用 AX 檢查焦點是否仍在起始欄位（issue #37）。
  除了逐句 raw，緩衝句落地（潤飾結果）走的也是同一道閘門。
  AX 明確指出焦點換了就不寫，該句改進剪貼簿並提示「欄位已切換，內容已入剪貼簿」——**只跳過那一句**，
  聽寫本身不中斷。某些 App 可能讓同一個欄位在兩次查詢間被判成不同 element，導致不該出現的跳過。
  緊急關閉這道閘門：

      defaults write io.saymend.app rawAppendGateEnabled -bool NO

  下次聽寫即生效（不必重開 App）；要恢復用 `-bool YES`，或 `defaults delete io.saymend.app rawAppendGateEnabled`。
  關閉後「欄位已切換」的攔阻完全消失（照常寫、不提示、不進剪貼簿、不留下跳過紀錄），畫面上也沒有任何
  「閘門已關」的提示（本開關只有 defaults，沒有 UI）。

  **關掉之後你承擔的是什麼**：合成鍵入／貼上一律落在**當下聚焦的元素**。若聽寫途中焦點真的換了
  （換欄位、或被切到別的 App），下一句就會被打進那裡，而且沒有任何提示——這正是這道閘門原本要擋的
  情況（issue #37）。所以這是拿「少一點誤判」換「多一點誤寫」，不是純粹的改善。

  **這個開關不會關掉密碼欄位保護。** 焦點在密碼欄位、或 AX 問不出 subrole 而只能當作是時，
  本段聽寫一律**當場停止**：不上屏、不進剪貼簿、不送雲端潤飾，歷史只留「發生過」的 metadata
  而不留逐字內容，並提示「密碼欄位不聽寫」。規格 §5.3 是硬規則，保險絲燒不到它。

## 開發
    swift test          # 核心邏輯全部單元測試
    swift build         # 編譯

## 授權

MIT，見 [LICENSE](LICENSE)。

## 靈感來源

本專案的產品概念靈感來自 [Soink](https://www.soink.ai/)——一款主打即時語音輸入與語音編輯的 Mac 語音鍵盤。
