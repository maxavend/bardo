# Bardo

Bardo is a privacy-first native macOS app for capturing, managing and transcribing conversations locally. Phases 0–4 are integrated on `main`; **Phase 5 — Transcription** is implemented on `feat/phase-5-transcription` in PR #7.

Bardo can import audio, record microphone-only conversations, capture system audio through the native macOS picker, capture system + microphone as independent originals with a derived conversation mix, and create persistent on-device transcripts with WhisperKit.

## Development requirements

- macOS 15 or later
- Xcode 16 or later with the Swift 6 toolchain
- XcodeGen 2.46.0 or later

CI validates the project on macOS 15 with Xcode 16.4.

```sh
brew install xcodegen
xcodegen generate
```

`project.yml` remains the source of truth; `Bardo.xcodeproj` and the generated `Bardo/Info.plist` are not committed.

## Current functionality

Bardo provides:

- native single-window SwiftUI macOS application;
- persistent Library with per-recording recovery isolation;
- native audio import into Bardo-managed storage;
- microphone-only capture through `AVAudioRecorder`;
- native `SCContentSharingPicker` selection for display, application or window;
- ScreenCaptureKit system-audio capture without persisted video;
- system-only and system + microphone dual-source recording;
- same-`SCStream` `.audio` and `.microphone` outputs for dual capture;
- independent `systemOriginal` and `microphoneOriginal` assets plus a regenerable `conversationMix`;
- playback preference for the mix with fallback to preserved originals;
- safe staging, stream-invalidation handling and restart recovery;
- a process-wide recording lease shared by microphone and system capture;
- persistent on-device transcription with WhisperKit 1.0.0;
- first-use Whisper model/tokenizer preparation with progress and disk-space preflight;
- bounded long-recording transcription in overlapping intervals rather than full-session PCM buffering;
- VAD, segment timestamps and word timestamps when supplied by WhisperKit;
- persistent `transcript.json` with a schema independent from the recording manifest;
- cancellation, retry and interrupted-processing recovery;
- minimal transcript UI with text selection, language/model/engine metadata and re-transcription.

## Transcription architecture

```text
managed recording audio
→ choose transcription source
→ prepare large-v3 Core ML model + tokenizer
→ load <= 300 s interval
→ 16 kHz mono Float samples
→ WhisperKit VAD + word timestamps
→ map interval timestamps to recording time
→ merge adjacent intervals using overlap acceptance boundaries
→ transcript.json (atomic publication)
→ Library transcript UI
```

Adjacent intervals overlap by one second. Acceptance boundaries divide that overlap so the same boundary event is not intentionally retained twice. Invalid/non-finite durations are rejected before planning.

For a System + Microphone recording, transcription requires the derived `conversationMix`. Bardo does not silently transcribe only one original and label it as the complete conversation.

## Models and dependency boundary

`project.yml` pins `argmaxinc/argmax-oss-swift` exactly to **1.0.0** and links only the `WhisperKit` product. Bardo does not link SpeakerKit, TTSKit or the ArgmaxOSS umbrella product in Phase 5.

The default model is:

```text
large-v3-v20240930_626MB
```

Model resources live under:

```text
Application Support/Bardo/Models/WhisperKit/
```

They are downloaded at runtime rather than bundled with the app. WhisperKit v1.0.0 obtains its tokenizer separately, so Bardo treats Core ML model + tokenizer preparation as one first-use setup operation.

See `THIRD_PARTY_NOTICES.md` for the preserved third-party license notice.

## Persistence

The recording manifest remains write schema **3** and V1/V2 remain readable.

Phase 5 adds a separate transcript schema rather than changing the recording manifest:

```text
Application Support/Bardo/Library/<recording-uuid>/
├── manifest.json       # Recording schema V3
├── transcript.json     # Transcript schema V1
└── audio/...
```

`transcript.json` contains recording identity, language when detected, segments, optional word timestamps/probabilities, and engine/model metadata. It is written to a same-directory temporary file and atomically renamed into place.

Bardo keeps the recovery policy:

`preserve → detect → inform → continue`

An interrupted `processing` state is reconciled on restart: a valid transcript becomes `completed`; a missing or corrupt transcript becomes retryable `failed`; managed audio remains untouched.

## Permissions and privacy

The generated application configuration includes:

- `NSMicrophoneUsageDescription`;
- `NSScreenCaptureUsageDescription`;
- Hardened Runtime configuration;
- `com.apple.security.device.audio-input`;
- `com.apple.security.network.client` for runtime model/tokenizer downloads.

Transcription is performed locally by WhisperKit after model resources are present. Phase 5 adds no cloud transcription service and sends no recording audio to an application-owned backend.

CI builds unsigned, so normally signed entitlement/TCC behavior and a real first model download remain interactive smoke evidence rather than automated claims.

## Tests

The Phase 5 production/reviewer gate passed **93 XCTest cases with 0 failures** in GitHub Actions CI #96 on macOS 15.7.7 Apple Silicon, Xcode 16.4 and Swift 6.1.2.

Automated coverage includes all inherited Phase 0–4 regressions plus bounded chunk planning, non-finite duration rejection, real AVFoundation interval loading, model discovery/preflight, tokenizer resource preparation, transcript schema/atomic persistence, restart recovery, retry/cancellation state, dual-source mix enforcement and full Library reconstruction after restart.

CI intentionally does not download the 600+ MB production model or claim real Neural Engine throughput. First-use model download, real Whisper transcript quality and long-session performance remain documented as `PARTIAL` evidence in `PROJECT_STATE.md`.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI: SwiftUI / AppKit lifecycle bridge
- Capture/audio: AVFoundation / AVFAudio / ScreenCaptureKit
- Transcription: WhisperKit 1.0.0
- Project generator: XcodeGen
- Recording manifest write schema: 3
- Transcript write schema: 1

## Explicitly out of scope

Phase 5 does not implement SpeakerKit, speaker diarization, speaker naming, summaries, live transcription, transcript editing, waveform work or any Phase 6+ functionality.

See `PROJECT_STATE.md` for exact certification evidence, reviewer repairs, recovery invariants, known physical evidence debt and the next permitted phase.
