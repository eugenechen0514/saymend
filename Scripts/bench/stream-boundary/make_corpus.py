#!/usr/bin/env python3
"""#19 量測語料：用 say 合成中文朗讀，輸出 $BENCH_DIR/$MANIFEST（預設 manifest.json）。

  BENCH_DIR=<資料夾> [VOICES=Meijia,Eddy] [MANIFEST=manifest.json] python3 make_corpus.py

VOICES 是 `say -v '?'` 列出的台灣中文聲音名稱；Meijia 以外都要寫成「名稱 (中文（台灣）)」，
這裡自動補上。逐句合成、句間插入靜音：沒有停頓時 Whisper 整段只切一個片段，根本沒有邊界。

kind：
- plain：沒有任何重複字，邊界上出現的重疊一律是邊界重複
- cross：合法重複**跨句**（第二次出現在下一句開頭）＝最容易被誤殺的情況
- inner：合法疊字在同一句內
- long：長段落，多片段
"""
import json, os, pathlib, re, subprocess

HERE = pathlib.Path(os.environ["BENCH_DIR"])
AUDIO = HERE / "audio"
AUDIO.mkdir(parents=True, exist_ok=True)

CORPUS = [
    ("p01", "plain", "今天天氣不錯，我想出去走走。順便去超市買一些水果，晚上再整理房間。"),
    ("p02", "plain", "明天早上九點有一個專案會議，記得先把上週的進度報告寄給大家，會議室在三樓。"),
    ("p03", "plain", "這個功能的設計還需要再討論，特別是錯誤處理的部分，我覺得目前的做法太複雜了。"),
    ("p04", "plain", "我們下個月要去日本旅行，機票已經訂好了，飯店還在比較價格，預算大概五萬塊。"),
    ("p05", "plain", "請幫我確認一下合約的第三條，付款期限好像寫錯了，應該是三十天而不是六十天。"),
    ("p06", "plain", "昨天晚上看了一部電影，劇情很精彩，演員的表現也很好，推薦你有空可以去看看。"),
    ("p07", "plain", "這次的測試結果顯示效能提升了百分之二十，但是記憶體用量也增加了，需要再觀察。"),
    ("p08", "plain", "我剛剛跟客戶通過電話，他們希望交貨日期提前一週，我們要評估一下產能夠不夠。"),
    ("c01", "cross", "這家餐廳的菜色不錯。不錯的地方是價格也很合理，下次可以再來。"),
    ("c02", "cross", "他說好。好的，那我們就照這個計畫進行，下午再確認細節。"),
    ("c03", "cross", "你說得對。對，就是這個問題，我們上次也遇到過同樣的狀況。"),
    ("c04", "cross", "我們先吃飯吧。吃飯的時候再慢慢討論這件事情，不用急。"),
    ("c05", "cross", "我覺得可以。可以先試做一個版本，再看看大家的反應。"),
    ("c06", "cross", "這件事情很重要。重要的是我們要在月底之前完成，不然會影響後面的進度。"),
    ("c07", "cross", "東西都準備好了。好了之後我們就出發，大概十點會到。"),
    ("c08", "cross", "那就這樣決定。決定之後就不要再改了，大家都辛苦了。"),
    ("i01", "inner", "好好好，我知道了，等一下就把檔案傳給你。"),
    ("i02", "inner", "對對對，就是這樣，你的理解完全正確。"),
    ("i03", "inner", "這個方案不錯不錯，比上一版好很多，可以直接拿去給主管看。"),
    ("i04", "inner", "謝謝謝謝，真的幫了我很大的忙，改天請你喝咖啡。"),
    ("l01", "long", "關於下一季的行銷計畫，我建議先把預算集中在社群媒體，因為去年的數據顯示這個管道的轉換率最高。另外，實體活動可以縮小規模，改成小型的工作坊。"),
    ("l02", "long", "今天的待辦事項有三件。第一，回覆客戶的郵件。第二，整理會議紀錄。第三，準備明天的簡報資料，記得加上最新的銷售數字。"),
    ("l03", "long", "這段程式碼有一個問題，當使用者在輸入框裡快速切換的時候，游標的位置會跑掉，我懷疑是事件處理的順序不對，需要加一個同步的機制。"),
    ("l04", "long", "週末我打算回老家一趟，順便帶爸媽去看醫生。他們最近身體還不錯，不過定期檢查還是比較放心，回來之後再跟你約時間吃飯。"),
]
VOICES = [(n.lower(), n if n == "Meijia" else f"{n} (中文（台灣）)")
          for n in os.environ.get("VOICES", "Meijia,Eddy").split(",")]
MANIFEST = os.environ.get("MANIFEST", "manifest.json")

# 逐句（以，。切）各自合成，句間插入靜音：模擬邊講邊想的停頓。
# 停頓長度輪流取，讓同一段裡有長有短；起始位置依段落序號錯開。
GAPS = [1.2, 0.4, 2.0, 0.8]

def parts_of(text):
    return [m for m in re.findall(r"[^，。]+[，。]?", text) if m.strip()]

items = []
for n, (cid, kind, text) in enumerate(CORPUS):
    for vkey, voice in VOICES:
        parts = []
        for i, frag in enumerate(parts_of(text)):
            path = AUDIO / f"{cid}-{vkey}-{i:02d}.wav"
            if not path.exists():
                subprocess.run(["say", "-v", voice, "-o", str(path), "--file-format=WAVE",
                                "--data-format=LEF32@48000", frag], check=True)
            parts.append({"path": str(path), "gapAfter": GAPS[(n + i) % len(GAPS)]})
        parts[-1]["gapAfter"] = 0
        items.append({"id": f"{cid}-{vkey}", "kind": kind, "voice": vkey, "text": text,
                      "parts": parts})

(HERE / MANIFEST).write_text(json.dumps(items, ensure_ascii=False, indent=1))
print(len(items), "clips")
