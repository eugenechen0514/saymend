#!/usr/bin/env python3
"""測試用的假 ssh：不連任何主機，把「遠端」模擬在本機的假家目錄裡。

- 每次被呼叫都把 argv 以一行 JSON 附加到 $FAKE_SSH_LOG。
- $FAKE_SSH_FAIL 有值：把它印到 stderr，exit 255（模擬驗證失敗、連不上等）。
- `-G <別名>`：印出固定的設定（hostname／user／port），模擬 `ssh -G`。
- `-N -R <遠端 socket>:<本機 socket>`：在遠端路徑 listen，每條連線轉發到本機 socket（模擬 sshd 的
  streamlocal 轉發），收到 SIGTERM 就收掉 socket 結束。
- 其他：把目的地之後的參數用空白接起來，交給 `sh -c` 執行（和 ssh 一樣由遠端 shell 解析），
  HOME 設成 $FAKE_REMOTE_HOME、PATH 設成 $FAKE_REMOTE_PATH（預設 /usr/bin:/bin），stdin 原樣傳過去。
"""

import json
import os
import signal
import socket
import subprocess
import sys
import threading

FLAGS_WITH_VALUE = {'-o', '-p', '-l', '-R', '-L', '-i', '-F', '-J', '-W', '-E', '-S', '-b', '-c', '-D', '-e', '-I', '-m', '-O', '-Q', '-w', '-B'}


def main() -> int:
    argv = sys.argv[1:]
    log = os.environ.get('FAKE_SSH_LOG')
    if log:
        with open(log, 'a', encoding='utf-8') as f:
            f.write(json.dumps(argv, ensure_ascii=False) + '\n')

    fail = os.environ.get('FAKE_SSH_FAIL')
    if fail:
        sys.stderr.write(fail + '\n')
        return 255

    options = {}
    flags = set()
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == '--':
            index += 1
            break
        if arg in FLAGS_WITH_VALUE:
            options.setdefault(arg, []).append(argv[index + 1])
            index += 2
            continue
        if arg.startswith('-') and len(arg) > 1:
            flags.add(arg)
            index += 1
            continue
        break
    if index >= len(argv):
        sys.stderr.write('fake ssh: 缺少目的地\n')
        return 255
    destination = argv[index]
    command = argv[index + 1:]

    if '-G' in flags:
        print(f'hostname {destination}.example.com')
        print('user alice')
        print('port 2222')
        return 0

    if '-N' in flags:
        remote, local = options['-R'][0].rsplit(':', 1)
        return forward(remote, local)

    env = {
        'HOME': os.environ['FAKE_REMOTE_HOME'],
        'PATH': os.environ.get('FAKE_REMOTE_PATH', '/usr/bin:/bin'),
    }
    ran = subprocess.run(['sh', '-c', ' '.join(command)], env=env, stdin=sys.stdin, check=False)
    return ran.returncode


def forward(remote: str, local: str) -> int:
    if os.path.exists(remote):
        sys.stderr.write(f'Error: remote port forwarding failed for listen path {remote}\n')
        return 255
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    previous = os.umask(0o177)
    try:
        server.bind(remote)
    finally:
        os.umask(previous)
    server.listen(16)
    stop = threading.Event()

    def on_term(_signum, _frame):
        stop.set()
        try:
            server.close()
        except OSError:
            pass

    signal.signal(signal.SIGTERM, on_term)
    server.settimeout(0.2)
    while not stop.is_set():
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=pump_pair, args=(conn, local), daemon=True).start()
    try:
        os.unlink(remote)
    except OSError:
        pass
    return 0


def pump_pair(conn: socket.socket, local: str) -> None:
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(local)
    except OSError:
        conn.close()
        return

    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        # 一邊結束就兩邊都關（和 ssh 的 channel 關閉一樣，對方會讀到 EOF）
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    threading.Thread(target=pump, args=(conn, upstream), daemon=True).start()
    pump(upstream, conn)


if __name__ == '__main__':
    sys.exit(main())
