#!/usr/bin/env python3
"""Saymend E2E 用的 OpenAI-compatible stub endpoint（規格 §7.5）。

用法：
    SCENARIO=fenced_json python3 Scripts/e2e-stub-server.py --port 18080

App 設定 → 一般 → LLM Base URL 填 http://127.0.0.1:18080/v1
每次請求會把 system/user role、UTF-8 byte 數、完整 payload 寫入 transcript，
並依 SCENARIO 回傳指定的 raw response。transcript 供驗收紀錄附證。
"""
import argparse, json, os, sys, datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIOS = {
    # E2E 第 7 項：strict envelope 與對抗輸入
    "fenced_json":      '```json\n{"intent":"new_content","text":"嗨"}\n```',
    "leading_prose":    '好的，以下是結果：{"intent":"new_content","text":"嗨"}',
    "bom":              '﻿{"intent":"new_content","text":"嗨"}',
    "zero_width_raw":   '{"intent":"new_content","text":"嗨​"}',
    "zero_width_esc":   '{"intent":"new_content","text":"\\u200b嗨"}',
    "unknown_intent":   '{"intent":"answer","text":"K8s 是容器編排系統"}',
    "homoglyph_intent": '{"intent":"new_cοntent","text":"嗨"}',   # Greek omicron
    "overlong_text":    '{"intent":"new_content","text":"' + ("長" * 25000) + '"}',
    "extra_field":      '{"intent":"new_content","text":"嗨","extra":"x"}',
    "missing_field":    '{"intent":"new_content"}',
    "multiple_objects": '{"intent":"new_content","text":"嗨"}{"intent":"new_content","text":"嗨"}',
    # 對照組：合法回應（第 8 項驗 budget 時要能正常上屏）
    "valid":            '{"intent":"new_content","text":"整理後的文字。"}',
}

TRANSCRIPT = os.environ.get("STUB_TRANSCRIPT", "/tmp/saymend-e2e-stub-transcript.jsonl")

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        req = json.loads(body)

        # 記錄 role 分離與 UTF-8 bytes（E2E 第 7/8 項的證據）
        entry = {
            "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "scenario": os.environ.get("SCENARIO", "valid"),
            "messages": [
                {
                    "role": m.get("role"),
                    "utf8_bytes": len(m.get("content", "").encode("utf-8")),
                    "content": m.get("content", ""),
                }
                for m in req.get("messages", [])
            ],
        }
        with open(TRANSCRIPT, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

        raw = SCENARIOS[os.environ.get("SCENARIO", "valid")]
        resp = {
            "id": "stub", "object": "chat.completion",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": raw},
                         "finish_reason": "stop"}],
        }
        payload = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass   # 靜音；transcript 才是證據

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    args = ap.parse_args()
    scenario = os.environ.get("SCENARIO", "valid")
    if scenario not in SCENARIOS:
        print(f"未知 SCENARIO：{scenario}\n可用：{', '.join(SCENARIOS)}", file=sys.stderr)
        sys.exit(1)
    print(f"stub 啟動 :{args.port}  scenario={scenario}  transcript={TRANSCRIPT}")
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
