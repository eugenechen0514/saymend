#!/usr/bin/env python3
"""#19 量測分析。讀 out/<config>/*.json（參數給資料夾；不給就讀 $BENCH_DIR/out/openai_*）。

每個「定稿送出點」之間是一個邊界（套件從已定稿片段的結束點重解）。
重疊 X＝前面已送出全文的尾端 k 字＝這次送出的開頭 k 字（k 取最大，上限 8）。
分類：X+X 出現在原文 → 合法（原文本來就連說兩次）；否則 → 邊界重複。

偵測規則（候選）：ref＝「讓邊界前進的那一趟」留下的暫時文字（解碼時看得到邊界前的音訊）。
- agree(m)：ref 不以 X 開頭，且 B 去掉 X 之後與 ref 的共同前綴 ≥ m → 判重複、裁掉
- noref：ref 不以 X 開頭就裁（不要求正面證據）
- blind(k0)：重疊 ≥ k0 就裁（對照組：無腦去重）
"""
import collections, json, os, pathlib, sys

HERE = pathlib.Path(os.environ.get("BENCH_DIR", "."))
MAXK = 8


def overlap(a, b):
    for k in range(min(MAXK, len(a), len(b)), 0, -1):
        if a[-k:] == b[:k]:
            return k
    return 0


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def edit_ops(hyp, ref):
    """Levenshtein：回傳 (替換, 漏字＝ref 有 hyp 沒有, 多字＝hyp 有 ref 沒有)。"""
    n, m = len(ref), len(hyp)
    d = [[(0, 0, 0, 0)] * (m + 1) for _ in range(n + 1)]   # (cost, sub, del, ins)
    for i in range(1, n + 1): d[i][0] = (i, 0, i, 0)
    for j in range(1, m + 1): d[0][j] = (j, 0, 0, j)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                d[i][j] = d[i - 1][j - 1]; continue
            c1, s1, de1, in1 = d[i - 1][j - 1]
            c2, s2, de2, in2 = d[i - 1][j]
            c3, s3, de3, in3 = d[i][j - 1]
            d[i][j] = min((c1 + 1, s1 + 1, de1, in1), (c2 + 1, s2, de2 + 1, in2), (c3 + 1, s3, de3, in3 + 1))
    _, sub, dele, ins = d[n][m]
    return sub, dele, ins


def emissions_with_ref(snaps):
    """照引擎規則重建送出序列，並附上每次送出時的 ref。"""
    out = []          # (textN, refN, source)
    ref = None
    last_c, last_cn, last_un = "", "", ""
    for i, s in enumerate(snaps):
        if s["confirmed"] != last_c:
            cn = s["confirmedN"]
            d = cn[len(last_cn):] if cn.startswith(last_cn) else cn
            if d:
                out.append((d, ref, "confirmed"))
            last_c, last_cn = s["confirmed"], cn
            nxt = snaps[i + 1] if i + 1 < len(snaps) else None
            ref = nxt["unconfirmedN"] if nxt and nxt["confirmed"] == s["confirmed"] else ""
        if s["unconfirmedN"] != last_un:
            last_un = s["unconfirmedN"]
    if last_un:
        out.append((last_un, ref, "tail"))
    return out


RULES = {
    "agree1": lambda x, rest, ref: ref is not None and not ref.startswith(x) and common_prefix(rest, ref) >= 1,
    "agree2": lambda x, rest, ref: ref is not None and not ref.startswith(x) and common_prefix(rest, ref) >= 2,
    "agree3": lambda x, rest, ref: ref is not None and not ref.startswith(x) and common_prefix(rest, ref) >= 3,
    "noref": lambda x, rest, ref: ref is not None and not ref.startswith(x),
    # 更保守：ref 連 X 的第一個字都對不上才裁；ref 為空（沒有佐證）不裁
    "noref1": lambda x, rest, ref: bool(ref) and not ref.startswith(x[0]),
    "blind1": lambda x, rest, ref: True,
    "blind2": lambda x, rest, ref: len(x) >= 2,
}


def analyze(config_dir, verbose=False):
    recs = [json.loads(p.read_text()) for p in sorted(config_dir.glob("*.json"))]
    st = collections.Counter()
    kdist = collections.Counter()
    rule = {r: collections.Counter() for r in RULES}
    cases = []
    waits = []
    for r in recs:
        if r.get("error"):
            st["error"] += 1
            continue
        st["clips"] += 1
        g = r["textN"]
        sub, dele, ins = edit_ops("".join(e for e in r["emissionsN"]), g)
        st["ref_chars"] += len(g); st["sub"] += sub; st["del"] += dele; st["ins"] += ins
        waits.append(r["finishedAt"] - r["feedEndAt"])
        em = emissions_with_ref(r["snapshots"])
        # 自我檢查：重建的序列要與 harness 算的一致
        if [e[0] for e in em] != [e for e in r["emissionsN"] if e]:
            st["rebuild_mismatch"] += 1
        acc = ""
        for j, (b, ref, src) in enumerate(em):
            if j > 0:
                st["boundaries"] += 1
                k = overlap(acc, b)
                if k:
                    x = acc[-k:]
                    legit = (x + x) in g
                    label = "legit" if legit else "dup"
                    st[label] += 1
                    st[f"{label}_{src}"] += 1
                    if not legit:
                        kdist[k] += 1
                    if ref is None or ref == "":
                        st[f"{label}_noref"] += 1
                    for name, fn in RULES.items():
                        cut = fn(x, b[k:], ref)
                        rule[name][("TP" if cut else "FN") if not legit else ("FP" if cut else "TN")] += 1
                    cases.append((r["id"], label, src, x, acc[-12:], b[:16], ref[:16] if ref else ref))
            acc += b
    waits.sort()
    st["wait_p50"] = round(waits[len(waits) // 2], 2) if waits else 0
    st["wait_p90"] = round(waits[int(len(waits) * 0.9)], 2) if waits else 0
    return st, kdist, rule, cases


def main():
    dirs = [pathlib.Path(a) for a in sys.argv[1:]] or sorted((HERE / "out").glob("openai_*"))
    for d in dirs:
        st, kd, rule, cases = analyze(d)
        print(f"\n### {d.name}")
        print(f"clips={st['clips']} errors={st['error']} rebuild_mismatch={st['rebuild_mismatch']} "
              f"boundaries={st['boundaries']} overlaps: dup={st['dup']} legit={st['legit']}")
        print(f"  dup by source: confirmed={st['dup_confirmed']} tail={st['dup_tail']} noref={st['dup_noref']}; "
              f"legit by source: confirmed={st['legit_confirmed']} tail={st['legit_tail']} noref={st['legit_noref']}")
        print(f"  dup k distribution: {dict(sorted(kd.items()))}")
        rc = st["ref_chars"] or 1
        print(f"  CER={(st['sub']+st['del']+st['ins'])/rc:.3f} (sub={st['sub']} del={st['del']} ins={st['ins']} / {rc} chars)  "
              f"release wait p50={st['wait_p50']}s p90={st['wait_p90']}s")
        for name, c in rule.items():
            print(f"  rule {name:7s}: TP={c['TP']} FN={c['FN']} FP={c['FP']} TN={c['TN']}")
        for c in cases:
            print("   ", c)


if __name__ == "__main__":
    main()
