#!/usr/bin/env python3
"""saymend-remote client：讓遠端主機上的 saymend-voice mod 使用 Mac 上的 Saymend 與喇叭。

這個檔案由 Saymend.app（設定 › 遠端）安裝到遠端的 ~/.saymend-remote/，並建立兩個 symlink：

    bin/saymend   參數原樣交給 Mac 上的 saymend CLI，stdout／stderr／結束碼原樣帶回。
    bin/say       `say [-v 語音] [文字]`：文字交給 Mac 的 `say`；沒給文字就讀 stdin（與 macOS 的 `say` 相同）。

Mac 那一側的橋接在 Saymend.app 裡；它經 `ssh -R` 把遠端的 ~/.saymend-remote/bridge.sock 接回 Mac。

線上格式（unix socket，NDJSON，UTF-8）：
    請求（第一行）  {"v":1,"cmd":"saymend","args":[…]}　或　{"v":1,"cmd":"say","voice":"…","text":"…"}
    回覆（多行）    {"out":"…"}、{"err":"…"}，最後一行 {"exit":N}
    client 中途關閉連線＝取消：Mac 上對應的聽寫會被丟棄、麥克風關閉。

連不上 Mac 時照 saymend CLI 的契約回報「app 未執行」（exit 3）：
    `status --json` 印 {"v":1,"app":"not_running","message":…}，其他 `--json` 指令印 code 為 unreachable 的 error。

只用 Python 標準函式庫，需要 python3（3.8 以上）。來源：Saymend repo 的 Resources/remote/saymend_remote.py。
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path

PROTOCOL = 1
REMOTE_DIR = '.saymend-remote'
SOCKET_NAME = 'bridge.sock'
SOCKET_ENV = 'SAYMEND_REMOTE_SOCKET'

UNREACHABLE = '連不上 Mac：Saymend 的遠端連線沒有開著，或 SSH 連線中斷'
DROPPED = '與 Mac 的連線中斷'


def send_frame(conn: socket.socket, frame: dict) -> bool:
    """送一行 NDJSON；對方已經離開就回 False。"""
    try:
        conn.sendall((json.dumps(frame, ensure_ascii=False) + '\n').encode('utf-8'))
    except OSError:
        return False

    return True


def default_socket_path() -> str:
    return os.environ.get(SOCKET_ENV) or str(Path.home() / REMOTE_DIR / SOCKET_NAME)


def exchange(request: dict) -> int | str:
    """把請求送給橋接，邊收邊印出 stdout／stderr。

    回傳 Mac 那邊的結束碼（int）；連不上或中途斷線則回傳原因（str）。
    """
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(default_socket_path())
    except OSError:
        conn.close()

        return UNREACHABLE

    try:
        if not send_frame(conn, request):
            return UNREACHABLE
        pending = b''
        while True:
            try:
                data = conn.recv(65536)
            except OSError:
                return DROPPED
            if not data:
                return DROPPED
            pending += data
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                try:
                    frame = json.loads(line)
                except ValueError:
                    continue
                if 'out' in frame:
                    sys.stdout.write(str(frame['out']))
                    sys.stdout.flush()
                elif 'err' in frame:
                    sys.stderr.write(str(frame['err']))
                    sys.stderr.flush()
                elif 'exit' in frame:
                    return int(frame['exit'])
    finally:
        conn.close()


def client_saymend(args: list[str]) -> int:
    """遠端的 `saymend`：行為照 saymend CLI 的輸出契約（v1）。"""
    outcome = exchange({'v': PROTOCOL, 'cmd': 'saymend', 'args': args})
    if isinstance(outcome, int):
        return outcome

    # 連不上 Mac：照契約回「app 未執行」（exit 3），另外用 code 區分是橋接的問題
    message = outcome
    sys.stderr.write(f'saymend: {message}\n')
    if '--json' in args:
        if args[:1] == ['status']:
            line = {'v': PROTOCOL, 'app': 'not_running', 'message': message}
        else:
            line = {'v': PROTOCOL, 'type': 'error', 'code': 'unreachable', 'message': message}
        sys.stdout.write(json.dumps(line, ensure_ascii=False) + '\n')
        sys.stdout.flush()

    return 3


def client_say(args: list[str]) -> int:
    """遠端的 `say`：`say [-v 語音] [文字…]`，沒給文字就讀 stdin。"""
    voice: str | None = None
    words: list[str] = []
    index = 0
    while index < len(args):
        arg = args[index]
        index += 1
        if arg in ('-v', '--voice'):
            if index >= len(args):
                sys.stderr.write('say: -v 後面要有語音名稱\n')

                return 2
            voice = args[index]
            index += 1
        elif arg.startswith('--voice='):
            voice = arg[len('--voice='):]
        elif arg == '--':
            words.extend(args[index:])
            break
        elif arg.startswith('-') and arg != '-':
            sys.stderr.write(f'say: 不支援的參數 {arg}（只支援 -v）\n')

            return 2
        else:
            words.append(arg)

    text = ' '.join(words) if words else sys.stdin.read()
    if text.strip() == '':
        return 0

    request: dict = {'v': PROTOCOL, 'cmd': 'say', 'text': text}
    if voice:
        request['voice'] = voice
    outcome = exchange(request)
    if isinstance(outcome, str):
        sys.stderr.write(f'say: {outcome}\n')

        return 1

    return outcome


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')

    # 被叫成 saymend／say（bin/ 裡的 symlink）
    name = os.path.basename(sys.argv[0])
    try:
        if name == 'saymend':
            return client_saymend(sys.argv[1:])
        if name == 'say':
            return client_say(sys.argv[1:])
    except KeyboardInterrupt:
        # 與 saymend CLI 收到 SIGINT 相同：取消，exit 5（連線關閉時橋接會取消那段聽寫）
        return 5
    except BrokenPipeError:
        return 1

    sys.stderr.write(
        'saymend-remote client：請透過 ~/.saymend-remote/bin/saymend 或 ~/.saymend-remote/bin/say 執行。\n'
        '安裝、連線與移除都在 Mac 上的 Saymend.app（設定 › 遠端）操作。\n'
    )

    return 2


if __name__ == '__main__':
    sys.exit(main())
