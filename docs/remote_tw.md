# 遠端：讓 SSH 主機上的 Claude Code 使用這台 Mac 的 Saymend

[English](remote.md) | 繁體中文

Claude Code 跑在用 SSH 連過去的主機上（Linux 也可以）時，saymend-voice mod 執行遠端的 client，經 SSH 轉回這台 Mac 聽寫與朗讀：

```
遠端   Claude Code（mod）──▶ ~/.saymend-remote/bin/saymend、bin/say（client）
                                  │ unix socket：~/.saymend-remote/bridge.sock
                                  ▼
       ════════════════ ssh -R（由 Saymend.app 建立、斷線重連）════════════════
                                  ▼
Mac    Saymend.app：每台主機一個橋接 socket ──▶ 控制介面（同 saymend CLI）、/usr/bin/say
```

連線、安裝 client 與斷線重連都由 Saymend.app 的「設定 › 遠端」管理，Mac 這一側不需要 python3，也不用開終端機。

## 1. 設定頁「遠端」

- **新增主機**：
  - 從 `~/.ssh/config` 挑：下拉選單列出 Host 別名，副標是 `user@hostname:port`。萬用字元（`*`、`?`）與否定（`!`）的 Host 不列。`Include` 會展開，相對路徑以 `~/.ssh` 為準。實際連線參數交給 `ssh -G <別名>` 解析，所以 `Include` 與 `Match` 都照你的設定。
  - 手動填主機、port、使用者。留白的部分照 ssh 自己的設定。
- **每台主機**：
  - 連線開關。
  - 狀態：未連線／連線中／已連上／重連中，加上最後一次的錯誤。
  - 「測試」：已連上時，從遠端經橋接問一次 status。沒連上時，臨時裝 client、建轉發、問一次 status，問完就收掉。
  - 「app 啟動時自動連線」。
  - 「移除遠端的 client」：連著的話會先斷線。
  - 「移除主機」：只從清單移除，遠端的 client 要先用「移除遠端的 client」刪掉。
- **已連上**時顯示兩行指令（路徑用遠端實際的家目錄），可一鍵複製，貼到遠端的 Claude Code 執行一次即可，設定會留著：

  ```
  /saymend bin /home/alice/.saymend-remote/bin/saymend
  /saymend speaker /home/alice/.saymend-remote/bin/say
  ```

- 清單存在 app 的設定裡（`remoteHosts`），只有連線參數，**沒有密碼或金鑰**。

需求：

- Mac：`ssh` 不輸入密碼就能登入那台主機（金鑰或 ssh-agent；Saymend 不會詢問密碼）。第一次連的主機，要先在終端機 `ssh` 一次接受主機金鑰。
- 遠端：`python3`（3.8 以上）。`sshd` 要允許轉發 unix socket（`AllowStreamLocalForwarding`，預設允許）。

## 2. 不能變的介面（mod 依賴這些）

- 遠端 client 的位置：`~/.saymend-remote/bin/saymend`、`~/.saymend-remote/bin/say`。兩個都是 symlink，指向同一支 `~/.saymend-remote/saymend_remote.py`。
  - `saymend …`：參數原樣轉給 Mac 的 `saymend` CLI，stdout、stderr 與結束碼原樣帶回（輸出契約見 [control-interface_tw.md](control-interface_tw.md)）。
  - `say [-v 語音] [文字]`：沒給文字就讀 stdin（與 macOS 的 `say` 相同）。
- 連不上 Mac 時（遠端連線沒開、SSH 中斷），client 回 exit 3：
  - `status --json` 印 `{"v":1,"app":"not_running","message":"連不上 Mac：…"}`。
  - 其他 `--json` 指令印 `{"v":1,"type":"error","code":"unreachable","message":"…"}`。
  - `say` 回 exit 1，stderr 印 `say: 連不上 Mac：…`。
- client 中途斷線（被 kill、SSH 中斷）＝取消：Mac 上對應的聽寫丟棄、麥克風關閉。
- 白名單（見第 4 節）：只接受固定的請求，不替遠端執行其他東西。

client 的原始檔是這個 repo 的 `Resources/remote/saymend_remote.py`，打包時放進 `Saymend.app/Contents/Resources/remote/`，連線時由 app 裝到遠端（每次連線都重裝，所以 app 更新後遠端的 client 會跟著更新）。這支檔案只有 client，Mac 那一側在 app 裡。來歷見第 7 節。

## 3. 線上格式（遠端 client ⇄ 橋接）

以這個 repo 為準：橋接端在 `Sources/SaymendCore/Remote/RemoteBridgeProtocol.swift`，client 端在 `Resources/remote/saymend_remote.py`。改格式時兩邊要一起改；app 每次連線都會重裝 client，所以兩邊不會長期不一致。

- unix socket，NDJSON，UTF-8。一條連線一個請求（第一行）：
  - `{"v":1,"cmd":"saymend","args":["dictate","--json","--silence-ms","1500"]}`
  - `{"v":1,"cmd":"say","voice":"Meijia","text":"…"}`（`voice` 可省略或為 `null`）
- 回覆：`{"out":"…"}`、`{"err":"…"}` 多行，最後一行 `{"exit":N}`。`saymend` 的輸出每行一個 frame（內容含結尾的 `\n`）。
- 拒絕（版本不符、不在白名單、格式錯誤）：`{"err":"saymend-remote: <原因>\n"}`、`{"exit":2}`。
- 請求那一行上限 256 KiB，10 秒內要送完。`say` 的文字超過 8000 字截掉。
- client 關閉連線＝取消。

## 4. 白名單

以 `RemoteBridgeProtocol.validateSaymendArgs` 為準，只放行 saymend-voice mod 會用到的子指令與參數：

| 請求 | 接受的參數 |
|---|---|
| `saymend status` | `--json` |
| `saymend stop`／`cancel`／`--version` | `--json` |
| `saymend events` | `--json`、`--presence <tag>`／`--presence=<tag>`（tag 為 `[a-z0-9_-]{1,32}`） |
| `saymend dictate` | `--json`、`--polish`、`--max-seconds`／`--silence-ms`／`--no-speech-seconds` 後接數字（只收 ASCII 數字，`N` 或 `N.N`，也可寫成 `--flag=N`） |
| `say` | `voice`：字母、數字、底線、空白與 `.()-`，1～64 字，不能以 `-` 開頭；文字走 stdin |

其他子指令或參數一律拒絕，不會碰到控制介面。

## 5. 安全性

- **只連你信任的主機，不要用多人共用的帳號。** 連線開著的期間，遠端主機上以同一個帳號執行的任何程式（以及那台主機的 root）都能叫這台 Mac 聽寫並拿到文字，也能讓喇叭說話。設定頁也寫著這段。
- 不存密碼、不存金鑰：一律呼叫系統的 `/usr/bin/ssh`，用你自己的 `~/.ssh/config`、ssh-agent 與金鑰。每次都加 `-o BatchMode=yes`，所以不會卡在密碼提示，驗證失敗的原因會顯示在該主機那一列。目的地前面一律加 `--`，主機名稱不可能被當成 ssh 的選項。目前只支援 SSH 這一種方式。
- 遠端觸發的聽寫在 HUD 上顯示「遠端 <主機> 聽寫中｜Esc 取消」，和本機 CLI 的「CLI 聽寫中」分得開；歷史的 App 欄是「遠端 <主機>（saymend）」。為此每台主機用各自的本機 socket，請求經 app 內的控制連線進來，連線標著主機名稱。這個標記只在 app 內部建立，外部行程經 `control.sock` 連進來的一律沒有來源，無從偽造。
- socket 與權限：
  - Mac 的橋接 socket 在 `~/Library/Application Support/Saymend/remote/<id>.sock`，權限 0600，資料夾 0700。連進來的對端 uid 必須是你自己。
  - 遠端的 `~/.saymend-remote` 是 0700，socket 由 sshd 建立。
  - 遠端不開任何 TCP port。
- 紀錄（`log stream --predicate 'subsystem == "io.saymend.app" AND category == "remote"'`）只有指令名稱、朗讀字數與結束碼，**不含聽寫與朗讀的內容**。
- 關掉開關或結束 Saymend 時：
  - ssh 結束，橋接 socket 收掉，進行中的遠端請求一律斷開。
  - 進行中的遠端聽寫取消、麥克風關閉。
  - app 若當掉，留下的 ssh 會在下次啟動時收掉：app 記下 pid 與行程啟動時間，兩者都對得上才動，所以不會誤殺重用 pid 的別的行程。

## 6. 實作說明

- **橋接直接在 app 內處理請求**，沒有另外執行 bundle 裡的 `saymend` helper。理由：
  1. 輸出不會走樣：`saymend` 請求在 app 內跑同一份 `CLIRunner`，輸出與結束碼和 CLI 是同一份程式碼。它經 `ControlServer.connectInProcess(origin:)` 的 socketpair 接進控制介面，走的是同一套協定與處理器。
  2. 來源標記無從偽造：連線帶著主機名稱，HUD 與歷史因此標得出遠端來源。若改成執行 helper，要嘛擴充線上協定讓外部行程自報來源（可偽造），要嘛靠 pid 對應。
  3. 不必另起行程，也不依賴 bundle 裡一定有 helper。
  4. 取消走同一條已驗證的路：client 斷線 → `CLIRunner.interrupt()`（dictate 會在同一條連線上請 app 取消，同 CLI 收到 SIGINT）→ 2 秒內沒確認就切斷控制連線，app 也會因斷線取消。
  - `say` 仍執行 `/usr/bin/say`（文字走 stdin），語音與行為和 macOS 的 `say` 完全一致。client 斷線時先 SIGTERM，3 秒後 SIGKILL。
- **ssh 指令**（`<共同>` 是 `-o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=no`，手動主機再加 `-p`／`-l`）：
  - 裝 client：`ssh <共同> -- <主機> "sh -c '<安裝步驟>'"`，client 檔從 stdin 送進去。安裝步驟（`RemoteClientInstall.installScript`）：建 0700 資料夾、寫入 client、建兩個 symlink、清掉上次留下的 `bridge.sock`、回報 `$HOME` 或缺 python3。
  - 轉發：`ssh <共同> -o ControlPath=none -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -R <遠端家目錄>/.saymend-remote/bridge.sock:<本機 socket> -- <主機>`
  - 檢查：`ssh <共同> -- <主機> '<遠端家目錄>/.saymend-remote/bin/saymend' status --json`，最多 5 次、間隔 1 秒。
  - 移除：`ssh <共同> -- <主機> "sh -c '<移除步驟>'"`。資料夾裡還有別的檔案就保留資料夾。
- **重連**：轉發斷了就從安裝重來，等 2 秒起、每次加倍、最多 30 秒；連上超過 60 秒才斷的，從 2 秒重算。下面這些錯誤重試也沒用，所以停在「未連線」、關掉開關並顯示原因：
  - 驗證失敗（`Permission denied`、`Too many authentication failures`）。一直用錯的金鑰重試，還可能觸發遠端的 fail2ban。
  - 主機金鑰沒確認（`Host key verification failed`）。
  - 遠端沒有 python3。
  - 遠端家目錄不能用於轉發（含冒號等）。
- ssh 沿用 app 的環境（含 launchd 給的 `SSH_AUTH_SOCK`）。從 Finder 啟動的 app PATH 很短，所以會在 PATH 後面補上 `/opt/homebrew/bin` 與 `/usr/local/bin`，讓 ssh config 裡的 `ProxyCommand` 找得到 Homebrew 裝的工具。
- **連線共用（ControlMaster）**：
  - 一般指令加 `ControlMaster=no`：可以沿用你已經開著的 master，但不會自己生出新的。設了 `ControlPersist` 時，背景 master 會一直開著 app 的 pipe，也不受 app 管理。
  - 轉發加 `ControlPath=none`：一律用自己的連線。共用 master 時轉發會掛在那個 master 上，關開關或結束 app 都收不掉。
- 每次連線會開三條 SSH 連線（安裝、轉發、檢查）。安裝與檢查可以沿用你已經開著的 master，轉發一定是新連線。
- 每台主機同時最多 16 個請求，超過的連線直接關掉，免得遠端失控時把 app 的 fd 用光。

## 7. 來歷：原本的 Python 橋接

這個功能收進 app 之前，Mac 這一側是一支 Python 腳本：claude-code-mods 的 `mods/saymend-voice/remote/saymend_remote.py`。同一個檔案也是遠端的 client；在 Mac 的終端機執行 `saymend_remote.py connect <主機>` 就是橋接，視窗要一直開著。

收進 app 後，那份檔案與它的測試已經從 claude-code-mods 移除，最後存在於該 repo 的 commit `fdeb73d`；mod 的 README 改成指向這份文件。現在的線上格式、白名單與安裝步驟都以這個 repo 為準（第 3、4、6 節），不需要對照那份檔案。

為了讓用過舊腳本的主機不必另外處理，下面這些刻意保持相容：

- 遠端 client 的位置、檔名、兩個 symlink 不變，線上格式不變。舊腳本裝過的主機，app 連線時會原地覆蓋。
- `saymend`／`say` 的行為、連不上時的 exit 碼與 JSON 形狀不變。

用過舊腳本的人會注意到的不同：

- Mac 這一側不再需要 python3 與終端機視窗。
- 每台主機各自一個本機 socket（舊腳本是所有主機共用一個），遠端聽寫才標得出是哪台主機。
- 所有 ssh 都加 `BatchMode=yes`、`ConnectTimeout=15`、`ControlMaster=no`，目的地前加 `--`；轉發另加 `ControlPath=none`。
- 驗證失敗、主機金鑰沒確認不再無限重試。
- 白名單的數字只收 ASCII（舊腳本的 `\d` 也收其他文字的數字）。
- client 連不上時的訊息改成「連不上 Mac：Saymend 的遠端連線沒有開著，或 SSH 連線中斷」，原本是「…saymend-remote 沒有在執行…」。`連不上 Mac` 開頭、exit 碼與 JSON 形狀都不變。
- client 檔只留 client 的部分，`connect`／`uninstall` 子指令移除了，改在設定頁操作。
- 同一個橋接 socket 同時最多 16 個請求。

## 8. 驗證紀錄

### 實機驗收（2026-11-28，Eugene，#95 與 #96 合併後重新打包的 app）

下面六項都通過：

- 設定頁從 `~/.ssh/config` 挑主機（真的設定檔）。
- 連上一台 Ubuntu 主機。
- 在遠端執行 `/saymend status`。
- 遠端發起的聽寫：HUD 顯示來源主機，文字回到遠端。
- 朗讀從 Mac 的喇叭出聲。
- 聽寫進行中關掉開關，麥克風立刻關閉。

### 自動化測試（2026-11-28，`feat/remote-bridge`，PR #96）

- `swift test` 全綠（SaymendCore 1065、SaymendControl 55、SaymendApp 170，含預設跳過的 harness）。新測試：
  - `RemoteBridgeProtocolTests`：白名單、請求解析、frame 形狀、紀錄摘要、主機參數、ssh config 解析。
  - `RemoteBridgeServerTests`：真的橋接 socket＋真的 `ControlServer`／`ControlService`，CLI 聽寫用假的麥克風與辨識器。驗了：
    - status 與 version 的輸出。
    - 遠端聽寫的 HUD 與歷史標記。
    - client 斷線與關掉橋接都會取消並關麥。
    - 白名單拒絕時不會建控制連線。
    - 遠端的 `--presence` 會計數。
    - `say` 的 stdin 與語音參數，斷線會結束 `say`。
    - 紀錄不含內容。
    - socket 0600、資料夾 0700。
  - `RemoteClientEndToEndTests`：真的 Python client（透過 `bin/saymend`、`bin/say` symlink）⇄ 橋接。驗了輸出與結束碼、kill client 會取消聽寫、白名單拒絕回 exit 2、`say`，以及連不上時的 exit 3、`not_running`、`unreachable`。
  - `RemoteLinkTests`：用假的 ssh（`Tests/SaymendCoreTests/Fixtures/Remote/fake_ssh.py`）把「遠端」模擬在本機的假家目錄，`-N -R` 時真的建 unix socket 轉發。驗了：
    - 裝 client、轉發、檢查整條路。
    - 每次 ssh 都帶 BatchMode 與 `--`。
    - 關掉開關會收掉 ssh 與 socket，進行中的遠端聽寫取消、麥克風關閉。
    - ssh 被 kill 後自動重連，遠端殘留的 socket 會被清掉。
    - 驗證失敗不重試；暫時性錯誤以 2、4、8 秒退避。
    - 遠端缺 python3 時停止。
    - 測試鈕用完會收掉臨時轉發；移除遠端的 client。
    - 手動主機帶 `-p`／`-l`。
  - `RemoteBridgeManagerTests`：清單持久化與去重、控制介面沒起來時的訊息、當掉後孤兒 ssh 的清理（啟動時間對不上不動）、`ssh -G` 解析副標。
- code review 後補的修正：上面的連線共用處理、16 條上限、「測試」的臨時轉發在 app 結束時也會收掉並記 pid、寫入 socket 時不持有狀態鎖（對端不讀時，關開關不會卡住 main thread）、pipe 寫入不觸發 SIGPIPE。這幾項各有測試，拿掉修正就會失敗（mutation 4 項）。
- mutation 11 項全部被抓到：9 項由斷言直接抓到；「測試鈕用完不收轉發」會讓產品碼卡住，測試以逾時失敗；「孤兒清理不比對啟動時間」一開始沒抓到，原因是斷言太早，補上等待後才抓到。
- 設定頁畫面：以 `RemoteSettingsSnapshot`（預設跳過，`SAYMEND_SNAPSHOT_DIR=<資料夾>`）畫成 PNG 檢查過版面。

### 還沒實機驗的

設定頁的這三個按鈕還沒有在實機上試過，只有自動化測試（用假的 ssh）：

- 「測試」。
- 「app 啟動時自動連線」。
- 「移除遠端的 client」。

另外，下面這些情況只有自動化測試，實機上沒有刻意觸發過：

- 網路斷線後自動重連。
- 驗證失敗、主機金鑰沒確認時的錯誤顯示。
- 結束 app 時收掉 ssh。
- app 當掉後，下次啟動清理留下的 ssh。
