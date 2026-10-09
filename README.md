# Bardo

Bardo is a native macOS app for recording or importing conversations and turning them into readable, searchable transcripts on the Mac.

## Product scope

The current product experience focuses on transcription. Bardo can:

- record microphone audio;
- capture system audio, optionally together with the microphone;
- import existing audio files;
- transcribe conversations locally with WhisperKit / Whisper Large v3 Turbo;
- identify speakers locally with SpeakerKit and let the user name them;
- edit transcript text while preserving the original recognition evidence;
- search conversations, transcript text, and participants;
- play managed audio and jump from transcript timestamps to playback positions.

Bardo does not include a generative meeting-minutes feature or a general-purpose LLM runtime.

## Privacy

Audio, transcripts, speaker labels, and participant names stay in Bardo's private local storage. Speech recognition and speaker identification run on the Mac. Network access is used only to download the required local speech and speaker resources when they are not already installed.

Bardo's folders under `~/Library/Application Support/Bardo` are owner-only (`0700`) and its recordings, manifests and transcripts are `0600`. Release builds are signed without debugging entitlements; `get-task-allow` and `disable-library-validation` exist only in `Bardo.Debug.entitlements` for hot reload.

## Reliability

- **Crash-safe capture.** System and meeting tracks are written as fragmented M4A (1 s fragments); microphone audio is staged as linear PCM in CAF and compressed to AAC after stopping. A crash, force quit or power loss keeps the audio captured until that moment.
- **Recovery.** Each capture keeps a `capture.json` with its title, start date and sources. After an interruption, *Interrupted recordings → Recover* adds the audio to the Library (regenerating the conversation mix).
- **Track independence.** A momentary encoder backlog is queued instead of ending the recording, and one failed track (for example the microphone) no longer stops the other.
- **Durable writes.** Manifests and transcripts are written to a temporary file, flushed with `fsync` and atomically renamed.
- **Setup never locks the app.** Recording, importing and playback never depend on the transcription models. First-run setup can be skipped or continued in the background, and removed models are offered again instead of blocking launch.
- **Model coordination.** Downloads and Core ML loads are shared between setup, Settings and transcription; a shared download stops only when every caller cancels, and models are never unloaded or removed while in use.
- **Complete transcripts.** The decoder gets no prompt tokens and a 3.5 compression-ratio threshold; both defaults previously dropped speech. `RealModelEndToEndTests` checks this against real models.

## Architecture

```text
audio import / microphone / system audio
                ↓
        managed recording store
                ↓
 Whisper Large v3 Turbo / WhisperKit
                ↓
      timestamped Transcript
                ↓ optional
      SpeakerKit diarization
                ↓
 transcript editing / search / playback
```

The main boundaries are:

- `Bardo/Audio`: capture, import, mixing, and playback;
- `Bardo/Transcription`: Whisper model management and transcription pipeline;
- `Bardo/Diarization`: speaker identification, alignment, naming policy, and previews;
- `Bardo/Persistence`: managed recordings and transcript persistence;
- `Bardo/Features/Library`: macOS library, transcript, search, and editing experience.

## Build

The Xcode project is generated from `project.yml` using XcodeGen.

```bash
brew install xcodegen
xcodegen generate
open Bardo.xcodeproj
```

The app target depends on `argmaxinc/argmax-oss-swift` 1.1.0 and links only the `WhisperKit` and `SpeakerKit` products.

## App icon

`Bardo/Resources/Assets.xcassets/AppIcon.appiconset` contains the complete macOS icon set. `project.yml` explicitly declares `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, and CI verifies that configuration and the compiled asset catalog.

## Tests

Run the macOS test suite with:

```bash
xcodebuild \
  -project Bardo.xcodeproj \
  -scheme Bardo \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Tests run in English (`language: en` in the scheme) so assertions on user-facing text do not depend on the Mac's language. `LocalizationTableTests` checks that the English and Spanish tables define the same keys with matching placeholders.

### Real-model check

`RealModelEndToEndTests` runs the real WhisperKit and SpeakerKit pipelines. CI has no models, so it is skipped unless you point it at a **copy** of installed models (an APFS clone is instant) and at speech recordings:

```bash
cp -cR ~/Library/Application\ Support/Bardo/Models/whisper-turbo ~/Library/Application\ Support/Bardo/Models/speaker-kit /tmp/bardo-models/
```

```bash
TEST_RUNNER_BARDO_E2E_MODELS_ROOT=/tmp/bardo-models TEST_RUNNER_BARDO_E2E_AUDIO=/path/to/dialogue.wav xcodebuild -project Bardo.xcodeproj -scheme Bardo -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:BardoTests/RealModelEndToEndTests
```

The long-recording check also takes `TEST_RUNNER_BARDO_E2E_LONG_AUDIO` and `TEST_RUNNER_BARDO_E2E_LONG_WORDS` (one keyword per turn, in order).

See `TESTING.md` for the physical macOS smoke-test checklist.
