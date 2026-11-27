# Remote: let Claude Code on an SSH host use this Mac's Saymend

English | [繁體中文](remote_tw.md)

When Claude Code runs on a host you reach over SSH (Linux works too), the saymend-voice mod runs a client on that host, which goes back through SSH to dictate and speak on this Mac:

```
Remote  Claude Code (mod) ──▶ ~/.saymend-remote/bin/saymend, bin/say (client)
                                  │ unix socket: ~/.saymend-remote/bridge.sock
                                  ▼
        ═══════════════ ssh -R (set up by Saymend.app, reconnects on drop) ═══════════════
                                  ▼
Mac     Saymend.app: one bridge socket per host ──▶ control interface (same as the saymend CLI), /usr/bin/say
```

Connecting, installing the client, and reconnecting are all managed in Saymend.app under **Settings › Remote** (遠端). The Mac side no longer needs python3 or a terminal window.

## 1. The Remote settings tab

- **Add a host**:
  - Pick from `~/.ssh/config`: a drop-down lists the Host aliases, with `user@hostname:port` as the subtitle. Hosts with wildcards (`*`, `?`) or negation (`!`) aren't listed. `Include` is followed, with relative paths resolved against `~/.ssh`. The actual connection settings are resolved by `ssh -G <alias>`, so `Include` and `Match` work exactly as in your config.
  - Or type host, port and user by hand. Anything left blank follows ssh's own config.
- **Per host**:
  - A connect switch.
  - Status: not connected / connecting / connected / reconnecting, plus the last error.
  - **Test**: when connected, asks for status once from the remote host through the bridge. When not connected, it temporarily installs the client, sets up the forward, asks once, and tears it down again.
  - **Connect when the app starts**.
  - **Remove the remote client**: disconnects first if connected.
  - **Remove host**: only removes it from the list. Remove the remote client first if you want it gone from the host.
- **Once connected**, two lines are shown (using the remote host's actual home directory) with a one-click copy button. Run them once in the remote Claude Code; the setting sticks:

  ```
  /saymend bin /home/alice/.saymend-remote/bin/saymend
  /saymend speaker /home/alice/.saymend-remote/bin/say
  ```

- The list lives in the app's settings (`remoteHosts`) and holds only connection parameters — **no passwords, no keys**.

Requirements:

- Mac: `ssh` must log in to the host without a password prompt (keys or ssh-agent; Saymend never asks for a password). For a host you've never connected to, `ssh` to it once in a terminal to accept its host key.
- Remote: `python3` (3.8+). `sshd` must allow unix-socket forwarding (`AllowStreamLocalForwarding`, allowed by default).

## 2. Interfaces that must not change (the mod depends on them)

- Client location: `~/.saymend-remote/bin/saymend` and `~/.saymend-remote/bin/say`. Both are symlinks to the same `~/.saymend-remote/saymend_remote.py`.
  - `saymend …`: arguments go unchanged to the Mac's `saymend` CLI; stdout, stderr and the exit code come back unchanged (output contract: [control-interface.md](control-interface.md)).
  - `say [-v voice] [text]`: reads stdin when no text is given (same as macOS `say`).
- When the Mac can't be reached (remote connection off, SSH dropped), the client exits 3:
  - `status --json` prints `{"v":1,"app":"not_running","message":"連不上 Mac：…"}`.
  - Other `--json` commands print `{"v":1,"type":"error","code":"unreachable","message":"…"}`.
  - `say` exits 1 and prints `say: 連不上 Mac：…` to stderr.
- A client that disconnects midway (killed, SSH dropped) = cancel: the matching dictation on the Mac is discarded and the microphone is closed.
- Whitelist (section 4): only fixed requests are accepted; nothing else is run on the remote's behalf.

The client's source is `Resources/remote/saymend_remote.py` in this repo. Packaging puts it in `Saymend.app/Contents/Resources/remote/`, and the app installs it on the host on every connect, so updating the app updates the remote client too. The file holds only the client; the Mac side lives in the app.

## 3. Wire format (remote client ⇄ bridge)

Same as `saymend_remote.py` in claude-code-mods, so existing clients keep working:

- Unix socket, NDJSON, UTF-8. One request per connection (the first line):
  - `{"v":1,"cmd":"saymend","args":["dictate","--json","--silence-ms","1500"]}`
  - `{"v":1,"cmd":"say","voice":"Meijia","text":"…"}` (`voice` may be omitted or `null`)
- Replies: any number of `{"out":"…"}` and `{"err":"…"}` lines, then a final `{"exit":N}`. `saymend` output is one frame per line, each including its trailing `\n`.
- Rejection (version mismatch, not whitelisted, malformed): `{"err":"saymend-remote: <reason>\n"}`, then `{"exit":2}`.
- The request line is limited to 256 KiB and must arrive within 10 seconds. `say` text beyond 8000 characters is truncated.
- The client closing the connection = cancel.

## 4. Whitelist

Same as the reference implementation, except numbers must be ASCII digits (stricter):

| Request | Accepted arguments |
|---|---|
| `saymend status` | `--json` |
| `saymend stop` / `cancel` / `--version` | `--json` |
| `saymend events` | `--json`, `--presence <tag>` / `--presence=<tag>` (tag is `[a-z0-9_-]{1,32}`) |
| `saymend dictate` | `--json`, `--polish`, and `--max-seconds` / `--silence-ms` / `--no-speech-seconds` followed by a number (`N` or `N.N`; `--flag=N` also works) |
| `say` | `voice`: letters, digits, underscore, space and `.()-`, 1–64 characters, not starting with `-`; the text goes through stdin |

Any other subcommand or argument is rejected and never reaches the control interface.

## 5. Security

- **Only connect to hosts you trust, and don't use shared accounts.** While a connection is on, any program running under the same account on the remote host (and that host's root) can make this Mac dictate and get the text back, or make its speaker talk. The settings tab says this too.
- No passwords or keys are stored. Saymend always runs the system `/usr/bin/ssh` with your own `~/.ssh/config`, ssh-agent and keys. Every call adds `-o BatchMode=yes`, so it never hangs on a password prompt; the reason for an authentication failure is shown on that host's row. The destination always follows `--`, so a host name can never be taken as an ssh option. SSH is the only supported method for now.
- A dictation triggered remotely shows "遠端 <host> 聽寫中｜Esc 取消" (remote <host> dictating | Esc to cancel) in the HUD, distinct from the local "CLI 聽寫中" (CLI dictating). The History tab's App column shows "遠端 <host>（saymend）".
  - This works because each host has its own local socket, and requests enter through an in-app control connection that is tagged with the host name.
  - The tag is created only inside the app. Connections that come in through `control.sock` from outside processes never carry an origin, so it can't be spoofed.
- Sockets and permissions:
  - The Mac bridge socket is `~/Library/Application Support/Saymend/remote/<id>.sock`, mode 0600, in a 0700 directory. The connecting peer's uid must be your own.
  - The remote `~/.saymend-remote` is 0700; sshd creates the socket there.
  - No TCP port is opened on the remote host.
- The log (`log stream --predicate 'subsystem == "io.saymend.app" AND category == "remote"'`) holds only command names, character counts for speech, and exit codes — **never dictated or spoken content**.
- Turning a switch off or quitting Saymend:
  - ssh exits, the bridge socket is removed, and every in-flight remote request is cut.
  - An in-flight remote dictation is cancelled and the microphone closed.
  - If the app crashes, the leftover ssh is cleaned up on the next launch. The app records both the pid and the process start time and acts only when both match, so a process that reused the pid is never killed.

## 6. Implementation notes

- **The bridge handles requests inside the app**; it does not run the bundled `saymend` helper. Why:
  1. The output can't drift: a `saymend` request runs the same `CLIRunner` in-process, so output and exit codes come from the same code as the CLI. It connects to the control interface through a socketpair from `ControlServer.connectInProcess(origin:)`, using the same protocol and handler.
  2. The origin tag can't be spoofed: the connection carries the host name, which is how the HUD and History can label remote sources. Running the helper would need either a wire-protocol extension that lets an external process declare its own origin (spoofable), or pid matching.
  3. No extra process to start, and no dependence on the helper being present in the bundle.
  4. Cancelling reuses an already-tested path: client disconnect → `CLIRunner.interrupt()`. For dictate this asks the app to cancel on the same connection, just like the CLI on SIGINT. If the app doesn't confirm within 2 seconds, the control connection is cut, and the app cancels because of the disconnect.
  - `say` still runs `/usr/bin/say` (text via stdin), so voices and behaviour match macOS `say` exactly. On client disconnect it gets SIGTERM, then SIGKILL after 3 seconds.
- **ssh commands** (`<common>` is `-o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=no`, plus `-p` / `-l` for manual hosts):
  - Install: `ssh <common> -- <host> "sh -c '<install steps>'"`, with the client file sent on stdin. The install steps are identical to the reference implementation: create the 0700 directory, write the client, create the two symlinks, remove a leftover `bridge.sock`, and report `$HOME` or a missing python3.
  - Forward: `ssh <common> -o ControlPath=none -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -R <remote home>/.saymend-remote/bridge.sock:<local socket> -- <host>`
  - Check: `ssh <common> -- <host> '<remote home>/.saymend-remote/bin/saymend' status --json`, up to 5 times, 1 second apart.
  - Uninstall: `ssh <common> -- <host> "sh -c '<uninstall steps>'"`. The directory is kept if it holds other files.
- **Reconnecting**: when the forward drops, the cycle starts again from install. The wait starts at 2 seconds and doubles up to 30; a connection that lasted more than 60 seconds resets it to 2. These errors won't go away by retrying, so the host stops at "not connected", the switch turns off, and the reason is shown:
  - Authentication failure (`Permission denied`, `Too many authentication failures`). Retrying with a wrong key could also trip fail2ban on the host.
  - Unconfirmed host key (`Host key verification failed`).
  - No python3 on the host.
  - A remote home directory that can't be used for forwarding (contains a colon, etc.).
- ssh inherits the app's environment (including the `SSH_AUTH_SOCK` launchd provides). An app started from Finder has a short PATH, so `/opt/homebrew/bin` and `/usr/local/bin` are appended, letting a `ProxyCommand` in ssh config find Homebrew tools.
- **Connection sharing (ControlMaster)**:
  - Regular commands add `ControlMaster=no`: they can reuse a master you already have open, but never start a new one. With `ControlPersist`, a background master would keep the app's pipes open and be outside the app's control.
  - The forward adds `ControlPath=none`: it always uses its own connection. On a shared master the forward would live in that master and survive turning the switch off or quitting the app.
- Each connection opens three SSH connections (install, forward, check). Install and check can reuse a master you already have open; the forward is always a new connection.
- Each host accepts at most 16 concurrent requests; extra connections are closed right away, so a runaway remote can't exhaust the app's file descriptors.

## 7. Differences from the reference implementation (`saymend_remote.py connect`)

- The Mac side is now the app; no python3 or terminal window needed. The remote client's wire format, location and behaviour are unchanged.
- One local socket per host (the reference used one shared socket), which is what lets remote dictations be labelled with the host.
- Every ssh call adds `BatchMode=yes` and `ConnectTimeout=15`, with `--` before the destination.
- Authentication failures and unconfirmed host keys are no longer retried forever.
- Whitelisted numbers must be ASCII (the reference's `\d` also accepted digits from other scripts).
- The unreachable message is now "連不上 Mac：Saymend 的遠端連線沒有開著，或 SSH 連線中斷" (instead of "…saymend-remote 沒有在執行…"). It still starts with `連不上 Mac`, and the exit codes and JSON shapes are unchanged.
- The client file keeps only the client; the `connect` / `uninstall` subcommands are gone (that's the settings tab now).

## 8. Verification record (2026-11-28, `feat/remote-bridge`)

- `swift test` all green (SaymendCore 1065, SaymendControl 55, SaymendApp 170, including harnesses skipped by default). New tests:
  - `RemoteBridgeProtocolTests`: whitelist, request parsing, frame shapes, log summaries, host arguments, ssh config parsing.
  - `RemoteBridgeServerTests`: a real bridge socket + real `ControlServer` / `ControlService`, with a fake microphone and recognizer for CLI dictation. Covers:
    - status and version output.
    - HUD and History labels for remote dictation.
    - Cancel and microphone close on client disconnect and when the bridge is stopped.
    - No control connection is made for rejected requests.
    - Remote `--presence` is counted.
    - `say` gets the text on stdin and the voice as an argument, and is stopped on disconnect.
    - Logs contain no content.
    - Socket 0600, directory 0700.
  - `RemoteClientEndToEndTests`: the real Python client (through `bin/saymend` / `bin/say` symlinks) ⇄ the bridge. Covers output and exit codes, killing the client cancels the dictation, whitelist rejection exits 2, `say`, and the exit 3 / `not_running` / `unreachable` reporting when unreachable.
  - `RemoteLinkTests`: a fake ssh (`Tests/SaymendCoreTests/Fixtures/Remote/fake_ssh.py`) simulates the "remote" in a fake home directory on this Mac and really forwards a unix socket for `-N -R`. Covers:
    - The whole install → forward → check path.
    - BatchMode and `--` on every ssh call.
    - Turning the switch off removes ssh and the sockets, and cancels an in-flight remote dictation and closes the microphone.
    - Reconnecting after ssh is killed, including removing the leftover remote socket.
    - No retry on authentication failure; 2/4/8-second backoff on transient errors.
    - Stopping when python3 is missing on the host.
    - The Test button cleans up its temporary forward; removing the remote client.
    - `-p` / `-l` for manual hosts.
  - `RemoteBridgeManagerTests`: list persistence and de-duplication, the message when the control interface is down, cleanup of orphaned ssh after a crash (left alone when the start time doesn't match), `ssh -G` subtitles.
- Fixes added after code review: the connection-sharing handling above, the 16-request cap, the Test button's temporary forward being stopped on quit and recorded in a pid file, socket writes no longer holding the state lock (so turning a switch off can't stall the main thread when the peer stops reading), and no SIGPIPE from pipe writes. Each has a test that fails when the fix is removed (4 mutations).
- All 11 mutations were caught: 9 by assertions directly. "Test button leaves the forward running" makes the production code hang, so the test fails by timeout. "Orphan cleanup ignores the start time" was missed at first because the assertion ran too early; adding a wait fixed that.
- Settings UI: rendered to PNG with `RemoteSettingsSnapshot` (skipped by default; `SAYMEND_SNAPSHOT_DIR=<dir>`) to check the layout.
- **Not verified**:
  - No real remote host was used; SSH was only simulated with the fake ssh.
  - The settings tab was not clicked through in a running packaged app.
  - No real remotely-triggered dictation with a real microphone.
  - `~/.ssh/config` parsing was only verified against test files, never a real config.
