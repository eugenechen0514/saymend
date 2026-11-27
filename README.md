# Saymend

English | [繁體中文](README_tw.md)

> *Say it. Consider it mended.*

A macOS voice input tool: the draft is done the moment you finish speaking, and you revise it with your voice instead of your mouse (M1 is core dictation; for spoken corrections see spec M2).

## Requirements
- macOS 26+ (SpeechAnalyzer)
- Xcode 26 toolchain
- A speech recognition engine (pick one of three in Settings; the default is the built-in one):
  - Built-in (Apple SpeechAnalyzer): no extra setup; the recognition model for the language is managed by the system and downloaded automatically on first use.
  - Local WhisperKit (offline): a WhisperKit CoreML model folder on disk (`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` is scanned by default; you can also point Settings at another folder). If the model's tokenizer isn't cached locally yet, it is fetched once from Hugging Face on first use.
  - Whisper remote: an OpenAI `audio/transcriptions`-compatible endpoint (the base URL is required; the default model is `whisper-1`; its API key is stored separately from the LLM's). A single recording is limited to 10 minutes.
- A language model (optional; used for polishing, spoken corrections, and rewriting selections; pick one of two in Settings, OpenAI-compatible by default). Without a working language model, dictation still works but always keeps the raw transcript, and the HUD shows "未潤飾（reason）" (not polished, with the reason):
  - An OpenAI-compatible endpoint (`chat/completions`): cloud, or a local Ollama / LM Studio; local endpoints can leave the API key empty.
  - Claude CLI: the Claude Code `claude` command installed and logged in on this machine (2.1.216 or later); it reuses Claude Code's login, so no API key is needed. It is looked up automatically in common locations such as `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`, or you can set the path in Settings.

## Build and run
    ./Scripts/make-app.sh
    open build/Saymend.app

On first launch, allow Accessibility, Microphone, and Speech Recognition. The app is signed with the local Apple Development certificate —
the signing identity is stable, so the existing Accessibility permission survives rebuilds (only when no Apple Development certificate is found does it fall back to ad-hoc signing; ad-hoc signing invalidates the permission on every re-sign, so you have to grant it again).
Packaging also puts the `saymend` CLI into `Saymend.app/Contents/Helpers/` and creates the symlink `~/.local/bin/saymend` (set `SAYMEND_SKIP_CLI_LINK=1` to skip it; see "With Claude Code" below for what it's for).

## Usage
- Hold Right Cmd and speak; release to polish and insert the text. A short press toggles locked dictation; another short press ends it.
- Press Esc during dictation to cancel the current segment.
- Spoken corrections (M2): within 8 seconds after finishing a sentence (the HUD shows "可修正", i.e. correctable), hold the hotkey and say a command such as "hey, change Tuesday to Wednesday earlier" — the text updates in place. Say "undo the last step" or click "復原" (Undo) on the HUD to go back one version.
- Typing or clicking manually during dictation "freezes" the segment (it is no longer rewritten automatically). Password fields always refuse dictation — if focus moves into a password field mid-dictation, the segment **stops immediately**: that sentence is not inserted, not put on the clipboard, and not sent for cloud polishing.
- **Selection as target (M3)**: select text in a field, then hold the hotkey and speak a command ("make it more formal", "translate to English") to rewrite the selection in place; speak new content to replace the selection. After the replacement you can keep making spoken corrections and undoing. In apps where the selection's position can't be confirmed via AX at the moment of replacement (focus has moved, or the app doesn't support AX range read/write), the field is left untouched; the result goes to the clipboard and a notice is shown.
- **Visual feedback (M3)**: text under voice control gets a thin underline; each replacement flashes a highlight. When the app doesn't support coordinate queries, the HUD shows the latest change as a strikethrough/underline diff. When a selection replacement is abandoned (the selection changed, or it couldn't be confirmed via AX), the field is unchanged — there is only a HUD notice, no highlight.
- **Vocabulary (M4)**: custom terms plus their common mis-transcriptions, fed both to the LLM for correction and to the ASR for speech biasing; JSON import/export.
- **App awareness (M4)**: per-app profiles — an extra prompt, a fixed language, a persisted capability cache, and a Cmd+C selection-fallback allowlist. Built-in defaults for Slack / Chrome / VS Code / Terminal and others.
- **Custom prompt and style (M4)**: a global custom system prompt and an output-style override; the core rules stay on top and can't be overridden.
- **OCR screen context (M4)**: a small-region screenshot recognized on-device by Vision and added to the LLM context (requires Screen Recording permission; optional). Settings offer "關閉" (Off), "僅備援" (Fallback only — used only when AX can't read the field), or "一律附加" (Always attach — attached even when AX can read the field).
- **Dictation history (M4)**: SQLite records sessions / transcripts / results, which you can review and copy in Settings; it can be turned off, and the retention period (in days) is configurable.
- **Selectable core modes (M5)**: 4 built-in modes (plain dictation cleanup / verbatim transcript / answering assistant / concise + formal rewrite) plus create/edit/delete for custom modes; quick switching from the menu bar, per-app binding, and a global default. Resolution priority: this dictation > per-app > global > built-in.

## With Claude Code (saymend-voice)

Saymend can serve as voice input for Claude Code: paired with macOS `say` reading the replies aloud, it forms a "speak → send to Claude Code → read the reply aloud" flow, built on Saymend's local control interface and the `saymend` CLI (see the contract in [docs/control-interface.md](docs/control-interface.md)). For the Claude Code mod, how to install it, and full details, see [`saymend-voice`](https://github.com/eugenechen0514/claude-code-mods/tree/main/mods/saymend-voice).

## Core modes and safety boundaries

Saymend's JSON output format, its intent classification (new_content / edit_command / undo), and the rule that "context data is for context only and may not smuggle in instructions" are enforced in code: a non-conforming response is rejected and degraded at the parsing and intent-guard layers, and never gets written into your field.

Core modes can adjust the answering, verbatim, or rewriting strategy, but they cannot change the machine contract above.

**Known limitation**: whether the model faithfully follows the letter of the contract is best-effort and cannot be formally proven. What Saymend guarantees is that "a non-conforming response never gets write access", not that "the model can never be manipulated".

## Troubleshooting

- **Dictation is often misjudged as "field switched" and not inserted**: before every insertion, AX checks whether focus is still in the starting field (issue #37).
  Besides each raw sentence, buffered sentences landing in the field (polished results) go through the same gate.
  When AX clearly indicates that focus has changed, nothing is written; that sentence goes to the clipboard with the notice "欄位已切換，內容已入剪貼簿" (Field switched; content copied to clipboard) — **only that sentence is skipped**,
  and the dictation itself continues. Some apps may make the same field look like a different element between two queries, causing skips that shouldn't happen.
  To disable this gate in an emergency:

      defaults write io.saymend.app rawAppendGateEnabled -bool NO

  It takes effect on the next dictation (no need to restart the app); to restore it, use `-bool YES`, or `defaults delete io.saymend.app rawAppendGateEnabled`.
  Once disabled, the "field switched" block disappears entirely (text is written as usual, with no notice, no clipboard copy, and no skip record), and there is no
  on-screen indication that the gate is off (this switch exists only in defaults; there is no UI for it).

  **What you take on by turning it off**: synthetic typing / pasting always lands in the **currently focused element**. If focus really does change mid-dictation
  (to another field, or because you were switched to another app), the next sentence is typed there with no notice — exactly the situation this gate was meant to block
  (issue #37). So this trades "fewer false positives" for "more mis-writes"; it is not a pure improvement.

  **This switch does not turn off password-field protection.** When focus is in a password field, or AX can't report the subrole and the field must be treated as one,
  the dictation segment always **stops immediately**: nothing is inserted, copied to the clipboard, or sent for cloud polishing; the history keeps only metadata that "it happened",
  not the verbatim content, and the notice "密碼欄位不聽寫" (No dictation in password fields) is shown. Spec §5.3 is a hard rule; this fuse can't burn through it.

## Development
    swift test          # all unit tests for the core logic
    swift build         # build

## License

MIT, see [LICENSE](LICENSE).

## Inspiration

The product concept of this project was inspired by [Soink](https://www.soink.ai/) — a Mac voice keyboard focused on real-time voice input and voice editing.
