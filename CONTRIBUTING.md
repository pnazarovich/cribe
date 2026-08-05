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
documented at the top of the file. Releasing a version also builds and signs the Sparkle update
artifacts — see [docs/releasing.md](docs/releasing.md).

### If SwiftPM hangs asking for your keychain password

Sparkle ships as a binary artifact, so SwiftPM downloads an `.xcframework` from GitHub. While
doing that it looks for stored `github.com` credentials in your login keychain, and if you have a
`github.com` item there whose ACL only trusts `git-credential-osxkeychain` (git puts one there
when you authenticate over HTTPS), macOS raises a keychain password prompt. Until you answer it,
`securityd` is blocked and *every* SwiftPM command hangs — including `swift package --help`.

Either click **Always Allow** once, or skip the keychain entirely:

```bash
swift build --disable-keychain
swift test --disable-keychain
swift package resolve --disable-keychain
```

The download itself needs no credentials — the artifact is a public release asset.

## Where things live

| Layer | Path | Rule |
| --- | --- | --- |
| Core logic | `Sources/TranscriberCore/` | No AppKit, no SwiftUI. Anything that can be a pure function is one. |
| ASR + audio | `Sources/TranscriberCore/{Audio,ASR}/` | Recording, VAD, WhisperKit engines. |
| Dictionary | `Sources/TranscriberCore/Dictionary/` | The three layers: `PromptBuilder`, `ReplacementEngine`, and the GPT prompt. |
| GPT | `Sources/TranscriberCore/GPT/` | API-key and ChatGPT-account auth, `SecretStore`, post-processing. |
| Pipeline | `Sources/TranscriberCore/Pipeline/` | `DictationController` — the state machine that wires it all together. |
| App | `Sources/Transcriber/` | Menu bar, HUD panel, dictation cards, dictionary editor. |
| CLI | `Sources/TranscriberCLI/` | Headless pipeline runner. |

Tests mirror that split: `Tests/TranscriberCoreTests/` for the core, `Tests/TranscriberAppTests/`
for behaviour that only exists as windows (the card stack).

Comments in this codebase explain *why*, not *what*, and are written in Russian — please keep
that convention so the file reads as one voice.
