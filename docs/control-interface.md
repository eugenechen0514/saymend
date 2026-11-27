# Local control interface and the `saymend` CLI (contract v1)

English | [繁體中文](control-interface_tw.md)

Lets other programs (for example a Claude Code mod) use Saymend as a voice input source: they ask the running Saymend.app to record an utterance, and the recognition result goes **only back to the caller** — it is not inserted into any field and doesn't touch the clipboard.

```
mod ──(runs)──▶ saymend CLI ──(unix socket, NDJSON v1)──▶ Saymend.app ──▶ microphone / recognition engine
```

- `saymend` is a thin client: it doesn't record and doesn't load models; it only forwards requests to the **running** app. If the app isn't running, it exits with code 3.
- When Claude Code runs on an SSH host, Saymend.app's **Settings › Remote** sets up a bridge, and the client on that host uses the same output contract through it; see [remote.md](remote.md).
- A mod depends only on this document's **CLI output contract** (section 1). The **wire protocol** between the app and the CLI (section 2) is an internal implementation detail, and the two can evolve independently.
- Location: `Saymend.app/Contents/Helpers/saymend` (not `Contents/MacOS/`: the file system is case-insensitive, so it would collide with the main executable `Saymend`). `Scripts/make-app.sh` signs it during packaging and creates the symlink `~/.local/bin/saymend` pointing into the bundle it just built (`SAYMEND_SKIP_CLI_LINK=1` skips this; a regular file with the same name is never overwritten).

## 1. CLI output contract (mods depend on this section)

Every `--json` output is NDJSON: one JSON object per line, flushed immediately after each line, and the first field of every object is `"v":1`. Control characters in strings are always escaped, so the output never contains a literal newline inside an object. Human-readable messages always go to stderr (`saymend: …`).

### `saymend status --json`

Prints one line and exits:

```json
{"v":1,"app":"running","state":"idle","source":null,"modelReady":true,"presence":{"loop":1}}
```

- `state`: `idle` | `recording` (microphone on) | `transcribing` (microphone off, recognition engine still working) | `polishing` (language-model polishing in flight)
- `source`: `hotkey` | `cli` | `null` (when idle). While a CLI dictation is in progress, the CLI takes precedence.
- `modelReady`: only the local WhisperKit engine has a "model not loaded yet" state; the built-in engine (SpeechAnalyzer) and Whisper remote always report `true`.
- `presence`: the number of `events` connections currently declaring each tag — the same count as `presence` in `events` (see `events` below).
- The 8-second continuation window after a hotkey dictation counts as `idle` externally (the microphone is off).
- App not running: prints `{"v":1,"app":"not_running"}` and exits 3.
- Without `--json`: prints one human-readable status line.

### `saymend dictate --json [--max-seconds N] [--silence-ms N] [--no-speech-seconds N] [--polish]`

Asks the app to start a **CLI-sourced** dictation and blocks until it ends.

```json
{"v":1,"type":"started"}
{"v":1,"type":"partial","text":"今天天氣"}
{"v":1,"type":"partial","text":"今天天氣很好"}
{"v":1,"type":"final","text":"今天天氣很好。","raw":"今天天气很好。","durationMs":4210}
```

- `started`: the microphone is on. If the dictation can't start (busy, permission), there is no `started` — the output is an error right away.
- `partial` (optional, zero or more): **the full text so far** (finalized + tentative text), sent only when it changes. The recognizer may revise tentative text, so a later `partial` is not guaranteed to extend the previous one.
- `final`:
  - `raw`: the recognition engine's original text.
  - `text`: the text for the caller = `raw` after on-device deterministic post-processing (see below); with `--polish`, it is the polished result run through the same post-processing. If polishing fails (timeout, malformed response), it degrades to the post-processed raw text without reporting an error.
  - `durationMs`: **the recording length** (microphone on to microphone off), excluding the time spent waiting for recognition or polishing after the recording ends.
- Options:

  | Option | Default | Description |
  |---|---|---|
  | `--max-seconds N` | 120 | Finalizes normally when reached (not an error). 0 < N ≤ 3600; decimals allowed. |
  | `--silence-ms N` | 0 (disabled) | Finalizes once N milliseconds of continuous silence follow **detected speech**. Silence before you start speaking never ends the dictation. 0 ≤ N ≤ 600000. |
  | `--no-speech-seconds N` | 0 (disabled) | Gives up if no speech at all is detected within N seconds of the start (exit 6). 0 ≤ N ≤ 3600. |
  | `--polish` | off | Polishes with the language-model provider configured in Settings (**may go to the cloud**, depending on your settings). By default there is no polishing and everything stays on-device. |

  Both forms are accepted: `--silence-ms 1200` and `--silence-ms=1200`.
- End conditions (any of): another process runs `saymend stop`; `--silence-ms`; `--max-seconds`; `--no-speech-seconds` (exit 6); the user presses the hotkey (= finalize) or Esc (= cancel, exit 5); `saymend cancel` (exit 5).
- Without `--json`: stdout prints **only the final text**, on one line; errors go to stderr only.
- **SIGINT / SIGTERM**: the CLI asks the app, on the same connection, to cancel and discard this dictation, and exits 5 (it still exits 5 if the app doesn't confirm within 2 seconds). A `final` that arrives after the cancel was sent is not printed.
- **CLI killed (including `kill -9`)**: as soon as the connection drops, the app cancels the dictation by itself and closes the microphone immediately.

#### On-device deterministic post-processing (everything that happens without polishing)

No network, no language model; the same input always produces the same output:

1. **Simplified → Traditional Chinese**: converted only when the global "output language" is zh-TW (the same converter as the post-polish Traditional Chinese guard: OpenCC traditionalize + twStandard + twIdiom). A CLI dictation has no target app, so it ignores per-app fixed languages and the hotkey session's temporary override.
2. **Vocabulary mis-transcription replacement**: the "common mis-transcriptions" registered in the Vocabulary tab of Settings are replaced with the correct term. Longer ones are replaced first; mis-transcriptions that start or end with a Latin letter or digit require a word boundary (`ai` won't eat the letters inside `said`) and are case-insensitive; Chinese is matched literally.

These two steps apply only to CLI dictation; hotkey dictation behaves as before.

#### Endpoint detection (`--silence-ms` / `--no-speech-seconds`)

Based mainly on the microphone's level (same scale as the HUD level bar: `min(1, RMS × 20)`):

- **Speech started**: the level stays above the threshold for 0.25 s in a row (filters out a cough or a tap on the desk), or the recognizer emits text that **grows**.
- **Speech finished**: after speech started, the level stays below the threshold and the recognized text doesn't grow, continuously for `--silence-ms`.
- **Threshold**: `max(0.08, noise floor × 2.5)`. The noise floor starts from the first sample and follows drops immediately; samples below the threshold pull it up normally, while samples above the threshold can only push it up very slowly (talking for ten seconds straight doesn't raise the threshold with your own voice). A noisy environment (fan, air conditioner) doesn't count as speech the moment the microphone opens.

When each CLI dictation ends, the app writes a numbers-only summary line to the system log (`io.saymend.app` / `cli`: "CLI 端點摘要：開口=… 最大位準=… 底線=… 門檻=…", i.e. endpoint summary: speech started=… max level=… floor=… threshold=…) for later calibration.

### `saymend stop [--json]`

Ends the CLI dictation that is currently **listening** (microphone on) and finalizes it; the text goes to the waiting `dictate`. On success it exits 0 (`--json` prints `{"v":1,"type":"ok"}`). If no CLI dictation is listening (one that is already transcribing doesn't count) → exit 4 with `code` `nothing_to_stop`.

### `saymend cancel [--json]`

Discards the current CLI dictation (at any stage: listening, transcribing, polishing); the waiting `dictate` exits 5. It doesn't affect hotkey dictation. On success it exits 0 (`--json` prints `{"v":1,"type":"ok"}`); if there is no CLI dictation → exit 4 (`nothing_to_stop`).

### `saymend events --json [--presence <tag>]`

A long-running stream of state changes from **all sources** (hotkey and CLI), plus changes in the presence counts:

```json
{"v":1,"type":"state","state":"idle","source":null,"presence":{},"at":"2026-11-26T14:30:37.469Z"}
{"v":1,"type":"state","state":"recording","source":"hotkey","presence":{},"at":"2026-11-26T14:35:57.731Z"}
{"v":1,"type":"state","state":"recording","source":"hotkey","presence":{"loop":1},"at":"2026-11-26T14:36:02.118Z"}
```

- The first line after connecting is a snapshot of the current state, followed by one line per change. `state` / `source` are the same as in `status`; `at` is ISO 8601 (UTC, milliseconds).
- `presence`: the number of `events` connections currently declaring each tag. Only tags with a count above 0 are listed (sorted by tag); with none, it is `{}`.
- Several changes within the same instant are coalesced and only the final result is sent; a line is skipped only when `state`, `source`, **and** `presence` are all unchanged — when a presence count changes, every `events` connection (including ones that declare no tag) gets a new line even if state / source didn't change.
- `--presence <tag>` (`--presence=<tag>` also works): while this `events` connection stays open, it means "one client has declared this tag".
  - tag: `[a-z0-9_-]{1,32}`. An invalid tag is a usage error (exit 2) and never connects to the app. One connection declares one tag; giving `--presence` twice is also exit 2. If the argument right after `--presence` starts with `--` (for example `--presence --json`), the tag counts as missing.
  - The snapshot on the first line already includes the connection itself: a connection declaring `loop` sees `presence.loop` of at least 1 on its first line.
  - Liveness is the connection itself — no heartbeats, no timeouts: when the CLI exits, is killed (including `kill -9`), or the app finds the peer gone, it stops counting, and the other connections immediately get the decreased count. A connection is counted once.
  - The app only counts; it doesn't interpret what a tag means.
  - `events` connections without `--presence` behave exactly as before and count toward no tag.
- Compatibility (presence exists since 0.2.0):
  - An old CLI (0.1.0) doesn't know `--presence` and exits 2 (`usage`); a mod can use that to fall back to omitting it.
  - A new CLI talking to an old app that hasn't been restarted (for example the bundle was rebuilt but the running process is still the old one): the old app accepts the request but doesn't count, and `state` / `status` output has **no `presence` field** (the CLI doesn't fill in `{}`). A missing field means the running app doesn't support presence.
  - An old CLI reading a new app: output as usual, just without the `presence` field.
- When the app quits, the stream ends: with `--json` it first prints one `{"v":1,"type":"error","code":"not_running",…}` line, then exits 3.
- Without `--json`: each line is `<at> <state> <source|->`, followed by ` <tag>=<n>,…` when presence isn't empty (e.g. `… idle - loop=2`).

### `saymend --version [--json]`

```
saymend CLI 0.2.0
Saymend.app 0.2.0
protocol v1
```

`--json`: `{"v":1,"cli":"0.2.0","app":"0.2.0","protocol":1}`. The CLI version is read from the Info.plist of the app bundle it lives in (the same one as the app). When the app isn't running, `app` is `null` (the text form prints "（未執行）", i.e. not running), and it still exits 0.

### Exit codes

| code | Meaning | Corresponding error `code` |
|---|---|---|
| 0 | Success | — |
| 1 | General error | `error`, `unsupported_version`, `microphone_unavailable` (the microphone couldn't start, not a permission issue), `asr_failed` (the recognition engine reported an error), `no_response` (the app didn't respond within 10 seconds) |
| 2 | Usage error | `usage` |
| 3 | App not running (or quit midway) | `not_running` |
| 4 | Busy, or no CLI dictation to stop / cancel | `busy`, `nothing_to_stop` |
| 5 | Cancelled | `cancelled` |
| 6 | No speech detected / empty result | `no_speech` (speech was never detected), `empty_result` (speech was detected but nothing was recognized) |
| 7 | Model not ready, or timeout | `model_not_ready` (failed while waiting for the local model, or no model selected), `timeout` (waiting for the recognition result after the recording ended exceeded the limit) |
| 8 | Insufficient permission | `permission_denied` (microphone permission denied; if it was never asked, the system permission prompt is shown, and this attempt still returns 8) |

On error with `--json`, one extra line `{"v":1,"type":"error","code":"…","message":"…"}` is printed (`message` is a human-readable explanation in Chinese — don't match on it).

## 2. Wire protocol v1 (app ⇄ CLI, internal implementation)

- Socket: `~/Library/Application Support/Saymend/control.sock` (the environment variable `SAYMEND_CONTROL_SOCKET` overrides it; the app and the CLI use the same resolution).
- Framing: NDJSON, UTF-8, lines separated by `\n`, 64 KiB per line at most. Every object carries `"v":1`; **the version is checked first**, and any mismatch is answered with `unsupported_version` and the connection is closed.
- One request per connection (the first line). After `dictate`, the connection may also send `{"v":1,"cmd":"cancel"}` (sent by the CLI when it receives SIGINT / SIGTERM); any other follow-up line is ignored. The CLI always writes `dictate` before it can send this `cancel` — a `cancel` as the first line is a standalone `saymend cancel`, which cancels **any** CLI dictation in progress.
- Requests: `{"v":1,"cmd":"status|version|stop|cancel|events"}`; `{"v":1,"cmd":"events","presence":"loop"}` (`presence` may be omitted or `null` = no declaration; a non-string or anything not matching `[a-z0-9_-]{1,32}` gets `usage` and the connection is closed); `{"v":1,"cmd":"dictate","maxSeconds":120,"silenceMs":0,"noSpeechSeconds":0,"polish":false}` (fields may be omitted = default value; invalid values get `usage`).
- Replies: `status` (`{"v":1,"type":"status","state":…,"source":…,"modelReady":…,"presence":{…}}`), `version` (`{"v":1,"type":"version","app":"0.2.0","protocol":1}`), `started`, `partial`, `final`, `state` (`{"v":1,"type":"state","state":…,"source":…,"presence":{…},"at":…}`), `ok`, `error`. After `status` / `version` / `ok` / `final` / `error`, the app closes the connection; `events` stays open.
- `presence` is the only nested object in the protocol, and its values are always integers. The app always sends it; a 0.1.0 app doesn't, and decoders treat a missing field as "the peer doesn't support it", not as `{}`.
- presence is a backward-compatible addition: no new command or message type, so the protocol version stays v1.

### Security boundaries

This interface can turn on the microphone from another process, so:

1. The socket file's permissions are **0600**.
2. Its directory is **0700** and must be owned by the current user; otherwise the app refuses to start the control interface. If the directory at the default path is looser, it is tightened to 0700 at startup; for a path overridden with `SAYMEND_CONTROL_SOCKET`, the app **does not change the permissions of an existing directory on your behalf** (it might be your home directory) and refuses to start if they are looser than 0700.
3. Every connection is checked with `getpeereid` right after accept; if the uid differs, the connection is closed immediately without sending a single byte. The CLI also verifies the server's uid (defense in depth).
4. A **dead** socket at the path (left behind by a crashed app) is removed and recreated; if someone is listening (another Saymend is running), the app doesn't take it over and only logs it; a file that isn't a socket is never deleted.
5. **Dictation is always visible**: while a CLI dictation is listening, the HUD shows a red microphone + level bar + "CLI 聽寫中｜Esc 取消" (CLI dictation in progress | Esc to cancel), in the same floating bar as hotkey dictation. A dictation started by a remote host through the bridge shows "遠端 <host> 聽寫中｜Esc 取消" (remote <host> dictating | Esc to cancel) instead ([remote.md](remote.md)).

## 3. Relationship with hotkey dictation

CLI dictation and hotkey dictation share the same microphone, recognition engine, and HUD (the recognition engine can run only one stream at a time), so they are **mutually exclusive**:

| Situation | Behavior |
|---|---|
| Hotkey dictation is listening, draining, or queued, or the previous sentence's polishing is still in flight | `dictate` → exit 4 (`busy`) |
| The 8-second continuation window after a hotkey dictation (no polishing in flight) | `dictate` starts normally and **archives the continuation window** (same as user activity): the CLI's text won't go into that field, so it isn't a continuation; without archiving, the window's expiry would also take down the HUD of the listening CLI dictation |
| Hotkey pressed while the CLI is listening | **Ends the dictation and finalizes** (like tapping the hotkey during locked dictation); the text goes to the waiting `dictate`; hotkey dictation does **not** start |
| Hotkey pressed while the CLI is transcribing / polishing | Only shows the notice "CLI 聽寫處理中" (CLI dictation is processing); hotkey dictation doesn't start |
| Esc at any stage of a CLI dictation | **Cancels and discards** (`dictate` exits 5). Esc is swallowed and not passed to the frontmost app — the same as pressing Esc during hotkey dictation |
| Typing, clicking, or switching apps during a CLI dictation | No effect (CLI text isn't inserted, so there is nothing to freeze) |

The behavior of hotkey dictation, spoken corrections, and the password-field hard rule is unchanged.

### The password-field rule (spec §5.3) doesn't apply to CLI dictation

§5.3 is triggered when "the **target** of the dictation is the focused password field": the reason for refusing is that the text would be typed into that field, hence "don't record, don't send to the LLM, don't keep history". A CLI dictation has no target field — by construction its result can't reach any field (this path has no inserter at all and doesn't touch the clipboard), so where the focus is has nothing to do with where the user's words are going. Applying the rule would only make the saymend-voice mod's loop mode (reads the reply aloud, then listens and sends automatically) fail at random whenever focus happens to sit in some password field (for example a 1Password unlock box), without buying any protection. See ADR 0005 for details.

### History

Recorded according to the existing "記錄聽寫歷史" (record dictation history) setting; the App column of the History tab shows **"CLI（saymend）"**, or **"遠端 <host>（saymend）"** for a dictation started by a remote host (`history_session.targetKind` is `"cli"` for both).

- Normal finalization: one `cliRaw` row (without polishing) or the polishing result kind (`newContent` / `degraded` …); the session's final text = the `text` returned to the caller.
- Cancelled or failed after text was recognized: one `outcomeDropped` row, described as `cli:<code>`.
- **Attempts with no content at all (gave up because nobody spoke) don't create a session**: the mod's loop mode opens such dictations over and over, and one blank record each time would flood the history.
- Caption hallucinations (canned subtitle phrases Whisper produces when there is no voice) are excluded from the result just as in hotkey dictation, and recorded as one `insertSkipped` / `captionHallucination` row.

## 4. Verification record (2026-11-26, `feat/control-cli`)

- Unit tests: `swift test` all green (SaymendCore 1005 tests, including 1 real-audio harness that is skipped by default; SaymendControl 41; SaymendApp 167). Tests for the new logic are in `Tests/SaymendControlTests/` (literal protocol shapes, options, real-socket server / client / permissions / uid rejection / CLI exit codes) and `Tests/SaymendCoreTests/{EndpointDetector,CLIDictationController,ControlService}Tests.swift`.
- Real-audio harness (skipped by default, `CLIDictationLiveHarness`): 7.2 seconds of Chinese speech synthesized with `say -v Meijia`, fed in real time with ambient noise padding before and after into the real WhisperKit (small) engine, with `--silence-ms 1200`: pauses within the sentence weren't cut off, and it finalized automatically about 0.5 s after the speech ended (threshold + tick); `raw` is Simplified Chinese, and `text` was converted to Traditional Chinese by OpenCC.
- On the real machine (running Saymend.app, built-in recognition engine, real microphone): `status`, `events` (both hotkey and CLI sources), `--version`, `dictate` with `--max-seconds` / `--no-speech-seconds`, `stop` / `cancel` from another process, SIGINT, SIGTERM, `kill -9` of the CLI; `dictate` returns 4 while hotkey dictation is listening or draining, starts normally during the continuation window, the hotkey finalizes a listening CLI dictation, and Esc cancels it; socket 0600 / directory 0700. Whether the microphone was on was confirmed with CoreAudio's per-process property (`kAudioProcessPropertyIsRunningInput`): after every way of ending (including `kill -9`), Saymend stopped capturing audio.
- Real person on the real machine (Eugene in person, through the Claude Code mod; built-in recognition engine, external headset microphone, `--silence-ms 1500`, part of it in loop mode with `--no-speech-seconds 10`): the complete path of speaking → automatic end on silence → text back to the CLI. The following is taken only from the history database and app log metadata, without any spoken content:
  - 2026-11-26 14:52–15:19 (UTC), 10 CLI dictations in total (`history_session.targetKind = cli`), each with final text (`cliRaw`).
  - All 10 recordings ended because of `silence` (automatic end on silence), with recording lengths of 5.9–32.1 seconds; the longest, 32-second one wasn't cut off mid-sentence.
  - Maximum voice level 1.0 (hit the ceiling); ambient noise floor 0.066–0.113, adaptive threshold 0.165–0.282.
  - In the same period there was one more dictation cancelled by `saymend cancel` (cancelled before endpoint detection had detected speech; not counted among the 10 above).
- **Not verified**: `--polish` has not been verified on the real machine; it has unit tests only.

## 5. Verification record: presence (2026-11-27, `feat/control-presence`)

- Unit tests: `swift test` all green (SaymendCore 1016 tests, including the harnesses that are skipped by default; SaymendControl 54; SaymendApp 167).
  - `Tests/SaymendControlTests/`: literal shapes of the `events` request with and without `presence`, every invalid tag is malformed; literal shapes of `state` / `status` with `presence` (only counts above 0, sorted by tag), and a 0.1.0 app that sends no presence decodes as "missing" and is never filled in with `{}`; both `--presence` forms in any order, and every invalid input is exit 2; CLI output over a real socket (JSON and text form).
  - `Tests/SaymendCoreTests/ControlServiceTests.swift`: a declaring connection sees itself on its first line; connections without a tag don't count and trigger no broadcast; presence changes are broadcast to every connection (even when state / source didn't change); disconnecting decrements and broadcasts; connecting and disconnecting within one turn sends no transient value; one connection counts once; `status` carries presence.
  - `Tests/SaymendCoreTests/ControlPresenceSocketTests.swift`: real socket + real `ControlServer` + real `ControlService`; disconnects decrement through the real path (the server sees EOF → `peerClosed`); an invalid tag on the wire gets `usage` and isn't counted.
- Real CLI processes (`ControlPresenceCLIProcessHarness`, skipped by default; `SAYMEND_CLI_BINARY=<new CLI> SAYMEND_OLD_CLI_BINARY=<0.1.0 CLI>`): two `saymend events --json --presence loop` processes plus an observer without a tag; the observer sees `{}` → `{"loop":2}`; `kill -9` on one → `{"loop":1}`; SIGTERM on the other (exit 5) → `{}`; `status --json` carries `"presence":{}`; an invalid tag exits 2. The 0.1.0 CLI: `events --json --presence loop` exits 2; `events --json` against the new app prints as usual, without a `presence` field.
- **Not verified**: not run against a running Saymend.app (a packaged build on the real machine); the mod's fallback path was not exercised.
