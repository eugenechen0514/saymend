# 本機控制介面與 `saymend` CLI（契約 v1）

讓別的程式（例如 Claude Code 的 mod）把 Saymend 當成語音輸入來源：請執行中的 Saymend.app 錄一段話，辨識結果**只回給呼叫端**，不上屏、不碰剪貼簿。

```
mod ──(執行)──▶ saymend CLI ──(unix socket, NDJSON v1)──▶ Saymend.app ──▶ 麥克風／辨識引擎
```

- `saymend` 是薄 client：不錄音、不載模型，只把請求送給**正在執行的** app。app 沒在跑就回 exit 3。
- mod 只依賴本文件的 **CLI 輸出契約**（第 1 節）。app ⇄ CLI 之間的**線上協定**（第 2 節）是內部實作，可以各自演進。
- 位置：`Saymend.app/Contents/Helpers/saymend`（不放 `Contents/MacOS/`：檔案系統不分大小寫，會和主程式 `Saymend` 撞名）。`Scripts/make-app.sh` 打包時一併簽章，並建立 `~/.local/bin/saymend` symlink 指向這次打包的 bundle（`SAYMEND_SKIP_CLI_LINK=1` 可略過；同名的一般檔案不會被覆蓋）。

## 1. CLI 輸出契約（mod 依賴這一節）

所有 `--json` 輸出都是 NDJSON：一行一個 JSON 物件、寫完立刻 flush、每個物件第一個欄位是 `"v":1`。字串一律跳脫控制字元，所以輸出裡不會出現真正的換行。人讀的訊息一律走 stderr（`saymend: …`）。

### `saymend status --json`

輸出一行後結束：

```json
{"v":1,"app":"running","state":"idle","source":null,"modelReady":true}
```

- `state`：`idle`｜`recording`（麥克風開著）｜`transcribing`（麥克風已關、辨識引擎還在處理）｜`polishing`（語言模型潤飾在途）
- `source`：`hotkey`｜`cli`｜`null`（閒置時）。CLI 聽寫進行中以 CLI 為準。
- `modelReady`：只有本機 WhisperKit 引擎有「模型還沒載入」的狀態；系統內建（SpeechAnalyzer）與 Whisper 遠端一律 `true`。
- 熱鍵聽寫結束後的 8 秒延續窗對外算 `idle`（麥克風是關的）。
- app 沒在跑：輸出 `{"v":1,"app":"not_running"}`，exit 3。
- 不加 `--json`：印一行人讀的狀態。

### `saymend dictate --json [--max-seconds N] [--silence-ms N] [--no-speech-seconds N] [--polish]`

請 app 開始一段 **CLI 來源**的聽寫，阻塞到結束。

```json
{"v":1,"type":"started"}
{"v":1,"type":"partial","text":"今天天氣"}
{"v":1,"type":"partial","text":"今天天氣很好"}
{"v":1,"type":"final","text":"今天天氣很好。","raw":"今天天气很好。","durationMs":4210}
```

- `started`：麥克風已開。開始不了（忙碌、權限）時不會有 `started`，直接是 error。
- `partial`（可選，0～多則）：**到目前為止的全文**（已定稿＋暫時文字），只在內容改變時送。暫時文字可能被辨識器改寫，所以後一則不保證是前一則加長。
- `final`：
  - `raw`：辨識引擎的原文。
  - `text`：給呼叫端用的文字＝`raw` 經過本機確定性後處理（見下）；加了 `--polish` 則是潤飾結果再經同一套後處理。潤飾失敗（逾時、格式不合）時降級成本機後處理過的原文，不報錯。
  - `durationMs`：**錄音長度**（開麥到關麥），不含錄音結束後等辨識、等潤飾的時間。
- 參數：

  | 參數 | 預設 | 說明 |
  |---|---|---|
  | `--max-seconds N` | 120 | 達到即正常定稿（不是錯誤）。0 < N ≤ 3600，可帶小數。 |
  | `--silence-ms N` | 0（不啟用） | **偵測到說話之後**連續靜音達 N 毫秒即定稿。還沒開口前不會因為靜音而結束。0 ≤ N ≤ 600000。 |
  | `--no-speech-seconds N` | 0（不啟用） | 開始後 N 秒內完全沒偵測到說話 → 放棄（exit 6）。0 ≤ N ≤ 3600。 |
  | `--polish` | 關 | 走設定中的語言模型 provider 潤飾（**可能上雲**，取決於設定）。預設不潤飾、全本機。 |

  兩種寫法都收：`--silence-ms 1200` 與 `--silence-ms=1200`。
- 結束條件（任一）：另一個行程執行 `saymend stop`；`--silence-ms`；`--max-seconds`；`--no-speech-seconds`（exit 6）；使用者按熱鍵（＝定稿）或 Esc（＝取消，exit 5）；`saymend cancel`（exit 5）。
- 不加 `--json`：stdout **只印最終文字**一行；錯誤只寫 stderr。
- **SIGINT／SIGTERM**：CLI 在同一條連線上請 app 取消這一段並丟棄，exit 5（app 2 秒內沒確認也照樣 exit 5）。已送出取消之後才到的 `final` 不會印出。
- **CLI 被 kill（含 `kill -9`）**：連線一斷，app 自己取消這一段，麥克風立刻關閉。

#### 本機確定性後處理（不潤飾時的全部處理）

不碰網路、不碰語言模型，同樣的輸入永遠得到同樣的輸出：

1. **簡轉繁**：全域「輸出語系」是 zh-TW 才轉（與潤飾後的簡繁保險絲同一個轉換器：OpenCC traditionalize＋twStandard＋twIdiom）。CLI 聽寫沒有目標 App，所以不看 per-app 固定語系、也不看熱鍵 session 的臨時覆蓋。
2. **詞彙表誤轉寫替換**：設定頁「詞彙表」登記的「常見誤轉寫」換成正確詞彙。長的先換；英數開頭／結尾的誤轉寫要求字邊界（`ai` 不會吃掉 `said` 裡的字）、不分大小寫；中文照字面比對。

這兩步只用在 CLI 聽寫；熱鍵聽寫的行為不變。

#### 端點判斷（`--silence-ms`／`--no-speech-seconds`）

以麥克風的音量位準為主（刻度與 HUD 音量條相同：`min(1, RMS × 20)`）：

- **開口**：位準連續高於門檻 0.25 秒（擋掉咳嗽、敲桌一下）；或辨識器吐出**變長的**文字。
- **說完**：開口之後，位準低於門檻、且辨識文字沒有變長，連續達 `--silence-ms`。
- **門檻**：`max(0.08, 噪音底線 × 2.5)`。噪音底線從第一個樣本起算、往下立即跟；低於門檻的樣本正常往上拉，高於門檻的樣本只能極慢地推（一口氣講十秒不會被自己的聲音抬高門檻）。吵雜環境（風扇、冷氣）不會一開麥就算開口。

每段 CLI 聽寫結束時，app 會在系統 log 記一行只有數字的摘要（`io.saymend.app`／`cli`：「CLI 端點摘要：開口=… 最大位準=… 底線=… 門檻=…」），供日後校準。

### `saymend stop [--json]`

結束目前**錄音中**的 CLI 聽寫並定稿，文字交給正在等待的 `dictate`。成功 exit 0（`--json` 輸出 `{"v":1,"type":"ok"}`）。沒有錄音中的 CLI 聽寫（含已經在辨識中）→ exit 4，`code` 為 `nothing_to_stop`。

### `saymend cancel [--json]`

丟棄目前的 CLI 聽寫（任何階段：錄音、辨識、潤飾），等待中的 `dictate` 以 exit 5 結束。不影響熱鍵聽寫。成功 exit 0（`--json` 輸出 `{"v":1,"type":"ok"}`）；沒有 CLI 聽寫 → exit 4（`nothing_to_stop`）。

### `saymend events --json`

長駐串流，涵蓋**所有來源**（熱鍵與 CLI）的狀態變化：

```json
{"v":1,"type":"state","state":"idle","source":null,"at":"2026-11-26T14:30:37.469Z"}
{"v":1,"type":"state","state":"recording","source":"hotkey","at":"2026-11-26T14:35:57.731Z"}
```

- 連上後第一行是當下快照，之後每次變化一行。`state`／`source` 同 `status`；`at` 為 ISO 8601（UTC、毫秒）。
- 同一瞬間連跳的狀態會合併，只送最後的結果；值沒變不送。
- app 結束 → 串流結束：`--json` 時先輸出一行 `{"v":1,"type":"error","code":"not_running",…}`，exit 3。
- 不加 `--json`：每行 `<at> <state> <source|->`。

### `saymend --version [--json]`

```
saymend CLI 0.1.0
Saymend.app 0.1.0
protocol v1
```

`--json`：`{"v":1,"cli":"0.1.0","app":"0.1.0","protocol":1}`。CLI 版本從它所在的 app bundle 的 Info.plist 讀（與 app 同一份）。app 沒在跑時 `app` 為 `null`（文字版印「（未執行）」），仍 exit 0。

### Exit codes

| code | 意義 | 對應的 error `code` |
|---|---|---|
| 0 | 成功 | — |
| 1 | 一般錯誤 | `error`、`unsupported_version`、`microphone_unavailable`（麥克風開不起來，非權限）、`asr_failed`（辨識引擎報錯）、`no_response`（app 10 秒內沒回應） |
| 2 | 用法錯誤 | `usage` |
| 3 | app 未執行（或中途結束） | `not_running` |
| 4 | 忙碌，或沒有可停／可取消的 CLI 聽寫 | `busy`、`nothing_to_stop` |
| 5 | 已取消 | `cancelled` |
| 6 | 沒偵測到說話／結果為空 | `no_speech`（從頭到尾沒判定開口）、`empty_result`（有開口但辨識不出字） |
| 7 | 模型未就緒或逾時 | `model_not_ready`（等本機模型時失敗、或沒選模型）、`timeout`（錄音結束後等辨識結果超過上限） |
| 8 | 權限不足 | `permission_denied`（麥克風權限被拒；尚未詢問過時會順手跳出系統授權視窗，這一次仍回 8） |

錯誤時若有 `--json`，另輸出一行 `{"v":1,"type":"error","code":"…","message":"…"}`（`message` 是給人看的中文說明，不要拿來比對）。

## 2. 線上協定 v1（app ⇄ CLI，內部實作）

- socket：`~/Library/Application Support/Saymend/control.sock`（環境變數 `SAYMEND_CONTROL_SOCKET` 可覆寫，app 與 CLI 用同一個解析）。
- 框架：NDJSON，UTF-8，`\n` 分行，一行上限 64 KiB。每個物件帶 `"v":1`；**版本先驗**，不符一律回 `unsupported_version` 並關閉連線。
- 一條連線一個請求（第一行）。`dictate` 連線之後可以再送 `{"v":1,"cmd":"cancel"}`（CLI 收到 SIGINT／SIGTERM 時送），其他後續行一律忽略。CLI 一定先寫出 `dictate` 才可能送這個 `cancel`——第一行的 `cancel` 是獨立的 `saymend cancel`，會取消**任何**進行中的 CLI 聽寫。
- 請求：`{"v":1,"cmd":"status|version|stop|cancel|events"}`；`{"v":1,"cmd":"dictate","maxSeconds":120,"silenceMs":0,"noSpeechSeconds":0,"polish":false}`（欄位可省略＝預設值；不合法回 `usage`）。
- 回覆：`status`（`{"v":1,"type":"status","state":…,"source":…,"modelReady":…}`）、`version`（`{"v":1,"type":"version","app":"0.1.0","protocol":1}`）、`started`、`partial`、`final`、`state`、`ok`、`error`。`status`／`version`／`ok`／`final`／`error` 之後 app 關閉連線；`events` 不關。

### 安全邊界

這個介面能從別的行程開麥克風，所以：

1. socket 檔權限 **0600**。
2. 所在目錄 **0700**，且必須是目前使用者擁有，否則 app 拒絕啟動控制介面。預設路徑的目錄原本較寬鬆時，啟動時收緊成 0700；用 `SAYMEND_CONTROL_SOCKET` 覆寫的路徑**不替使用者改既有目錄的權限**（可能是家目錄），比 0700 寬就拒絕啟動。
3. 每條連線 accept 之後立刻 `getpeereid`，uid 不同就直接關閉，一個位元組都不回。CLI 端也驗 server 的 uid（縱深防禦）。
4. 路徑上若是**死掉的** socket（app 當掉留下的）就清掉重建；有人在 listen（另一個 Saymend 在跑）就不搶、只記 log；不是 socket 的檔案一律不刪。
5. **錄音一定看得見**：CLI 聽寫錄音時 HUD 顯示紅色麥克風＋音量條＋「CLI 聽寫中｜Esc 取消」，與熱鍵聽寫同一個浮條。

## 3. 與熱鍵聽寫的關係

CLI 聽寫與熱鍵聽寫共用同一組麥克風、辨識引擎與 HUD（辨識引擎同一時間只能跑一條串流），所以**互斥**：

| 情境 | 行為 |
|---|---|
| 熱鍵聽寫錄音中、排空中、排隊中，或上一句潤飾還在途 | `dictate` → exit 4（`busy`） |
| 熱鍵聽寫結束後的 8 秒延續窗（沒有在途潤飾） | `dictate` 照常開始，並**封存延續窗**（同使用者活動）：CLI 的文字不會進那個欄位，不是延續；不封存的話延續窗到期會把 CLI 錄音中的 HUD 一起收掉 |
| CLI 錄音中按熱鍵 | **結束錄音並定稿**（同鎖定聽寫時點一下熱鍵），文字交給等待中的 `dictate`；**不**開始熱鍵聽寫 |
| CLI 辨識／潤飾中按熱鍵 | 只提示「CLI 聽寫處理中」，不開始熱鍵聽寫 |
| CLI 聽寫任何階段按 Esc | **取消並丟棄**（`dictate` exit 5）。Esc 被吞掉、不傳給前景 App——與熱鍵聽寫中按 Esc 一致 |
| CLI 聽寫中打字、點滑鼠、切 App | 不影響（CLI 的文字不上屏，沒有東西要凍結） |

熱鍵聽寫、口頭修正、密碼欄位硬規則的行為都沒有改變。

### 密碼欄位規則（規格 §5.3）不適用於 CLI 聽寫

§5.3 的觸發條件是「聽寫的**目標**是聚焦中的密碼欄」：拒絕的理由是文字會被打進那個欄位，所以「不錄音、不送 LLM、不留歷史」。CLI 聽寫沒有目標欄位——結果在構造上就到不了任何欄位（這條路上根本沒有 inserter、不碰剪貼簿），焦點在哪裡和使用者說的話要去哪裡無關。套用它只會讓免手動迴圈在焦點剛好停在某個密碼欄（例如 1Password 解鎖框）時隨機失敗，換不到任何保護。詳見 ADR 0005。

### 歷史紀錄

照現有的「記錄聽寫歷史」設定記錄，歷史分頁的 App 欄顯示 **「CLI（saymend）」**（`history_session.targetKind = "cli"`）。

- 正常定稿：一列 `cliRaw`（不潤飾）或潤飾的結果類別（`newContent`／`degraded`…），session 的最終文字＝回給呼叫端的 `text`。
- 取消、失敗但已辨識出文字：一列 `outcomeDropped`，說明 `cli:<code>`。
- **沒有任何內容的嘗試（沒人說話就放棄）不開 session**：免手動迴圈會反覆開這種聽寫，每次一筆空白紀錄會把歷史洗掉。
- 字幕幻覺（Whisper 在沒人聲時解出的罐頭語）與熱鍵聽寫同樣不算進結果，記一列 `insertSkipped`／`captionHallucination`。

## 4. 驗證紀錄（2026-11-26，`feat/control-cli`）

- 單元測試：`swift test` 全綠（SaymendCore 1005 項，含 1 項預設跳過的實音訊 harness；SaymendControl 41 項；SaymendApp 167 項）。新邏輯的測試在 `Tests/SaymendControlTests/`（協定字面形狀、參數、真 socket 的 server／client／權限／uid 拒絕／CLI exit code）與 `Tests/SaymendCoreTests/{EndpointDetector,CLIDictationController,ControlService}Tests.swift`。
- 實音訊 harness（預設跳過，`CLIDictationLiveHarness`）：`say -v Meijia` 合成的 7.2 秒中文語音，以即時速度、前後墊環境噪音餵進真的 WhisperKit（small）引擎，`--silence-ms 1200`：句中停頓沒被切斷，說完後約 0.5 秒（門檻＋tick）自動定稿；`raw` 簡體、`text` 經 OpenCC 轉繁。
- 實機（執行中的 Saymend.app、系統內建辨識引擎、真麥克風）：`status`、`events`（熱鍵與 CLI 兩種來源）、`--version`、`dictate` 的 `--max-seconds`／`--no-speech-seconds`、另一行程 `stop`／`cancel`、SIGINT、SIGTERM、`kill -9` CLI；熱鍵錄音中與排空中 `dictate` 回 4、延續窗中 `dictate` 照常開始、CLI 錄音中按熱鍵定稿、按 Esc 取消；socket 0600／目錄 0700。麥克風開關以 CoreAudio 的 per-process 屬性（`kAudioProcessPropertyIsRunningInput`）確認：每一種結束方式（含 `kill -9`）之後 Saymend 都不再收音。
- **沒驗的**：真人對麥克風說話經 app 的完整路徑（說話 → 靜音自動結束 → 文字回到 CLI）；該路徑的端點判斷與辨識由上面的實音訊 harness 驗證，但麥克風增益、距離、房間迴響不在其中。`--polish` 只有單元測試。
