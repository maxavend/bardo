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

See `TESTING.md` for the physical macOS smoke-test checklist.
