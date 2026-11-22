#!/usr/bin/env python3
"""#19：現行送出序列（harness 照舊規則算的 emissionsN）vs 正式引擎重播（含邊界重複判斷）。

對每組設定比：邊界上的重疊（重複／合法）、與原文的編輯距離（替換／漏字／多字）。
被裁掉的合法重複會表現成「合法重疊變少」且「漏字變多」；裁掉的真重複會表現成「多字變少」。
"""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from analyze import overlap, edit_ops  # noqa: E402  (analyze.py 的 main() 在 import 時會跑，下面避開)


def boundary_stats(emissions, truth):
    dup = legit = 0
    cases = []
    acc = ""
    for j, b in enumerate(e for e in emissions if e):
        if j > 0:
            k = overlap(acc, b)
            if k:
                x = acc[-k:]
                if (x + x) in truth:
                    legit += 1
                else:
                    dup += 1
                    cases.append((x, acc[-10:], b[:12]))
        acc += b
    return dup, legit, cases


def main():
    for d in [pathlib.Path(a) for a in sys.argv[1:]]:
        rp = d.parent / (d.name + "-replay")
        tot = {"before": [0, 0, 0, 0, 0], "after": [0, 0, 0, 0, 0]}   # dup legit sub del ins
        changed = []
        leftover = []
        for f in sorted(d.glob("*.json")):
            r = json.loads(f.read_text())
            if r.get("error"):
                continue
            rr = json.loads((rp / f.name).read_text())
            g = r["textN"]
            for tag, em in (("before", r["emissionsN"]), ("after", rr["finalizedN"])):
                dup, legit, cases = boundary_stats(em, g)
                sub, dele, ins = edit_ops("".join(em), g)
                for i, v in enumerate((dup, legit, sub, dele, ins)):
                    tot[tag][i] += v
                if tag == "after" and cases:
                    leftover += [(r["id"],) + c for c in cases]
            if [e for e in r["emissionsN"] if e] != [e for e in rr["finalizedN"] if e]:
                changed.append((r["id"], r["emissionsN"], rr["finalizedN"]))
        print(f"\n### {d.name}")
        for tag in ("before", "after"):
            dup, legit, sub, dele, ins = tot[tag]
            print(f"  {tag:6s}: dup={dup} legit={legit}  sub={sub} del={dele} ins={ins}")
        for c in changed:
            print("   changed:", c[0])
            print("     before:", c[1])
            print("     after :", c[2])
        for c in leftover:
            print("   leftover dup:", c)


if __name__ == "__main__":
    main()
