# Contributing

## Tests

```bash
swift test
```

Everything worth testing lives in pure functions, so the suite runs in seconds without a
microphone, a network, or a signed app. New behaviour should arrive with a test; bug fixes
should arrive with the test that reproduced the bug.

The pipeline can also be exercised end to end without the UI:

```bash
say -v Milena "Сделай коммит и задеплой на гитхаб" -o /tmp/fx.aiff
swift run TranscriberCLI /tmp/fx.aiff --lang ru --no-gpt
```

## Building the app

**Use `bash scripts/build-app.sh`, never `swift build`, to produce `Transcriber.app`.**
The script drives `xcodebuild` and then assembles the bundle by hand. `swift build` links the
executable fine but leaves the KeyboardShortcuts resource bundle where the generated SPM
resource accessor cannot find it, and the app traps at runtime the first time it reads a
shortcut. `swift build` and `swift test` are the right tools for the library and the tests —
just not for the `.app`.

`scripts/release.sh` is the signed-and-notarized variant; its environment variables are
documented at the top of the file.

## Where things live

| Layer | Path | Rule |
| --- | --- | --- |
| Core logic | `Sources/TranscriberCore/` | No AppKit, no SwiftUI. Anything that can be a pure function is one. |
| ASR + audio | `Sources/TranscriberCore/{Audio,ASR}/` | Recording, VAD, WhisperKit engines. |
| Dictionary | `Sources/TranscriberCore/Dictionary/` | The three layers: `PromptBuilder`, `ReplacementEngine`, and the GPT prompt. |
| GPT | `Sources/TranscriberCore/GPT/` | API-key and ChatGPT-account auth, Keychain, post-processing. |
| Pipeline | `Sources/TranscriberCore/Pipeline/` | `DictationController` — the state machine that wires it all together. |
| App | `Sources/Transcriber/` | Menu bar, HUD panel, dictation cards, dictionary editor. |
| CLI | `Sources/TranscriberCLI/` | Headless pipeline runner. |

Tests mirror that split: `Tests/TranscriberCoreTests/` for the core, `Tests/TranscriberAppTests/`
for behaviour that only exists as windows (the card stack).

Comments in this codebase explain *why*, not *what*, and are written in Russian — please keep
that convention so the file reads as one voice.
