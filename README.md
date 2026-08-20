# Bardo

Bardo is a privacy-first native macOS app for capturing, managing, transcribing and identifying speakers in conversations locally. Phases 0–5 are integrated on `main`; **Phase 6 — Diarization** is implemented on `feat/phase-6-diarization` in PR #8.

Bardo can import audio, record microphone-only conversations, capture system audio through the native macOS picker, capture system + microphone as independent originals with a derived conversation mix, create persistent on-device transcripts with WhisperKit, and enrich those transcripts with local SpeakerKit speaker labels.

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
- independent source originals plus a regenerable `conversationMix`;
- playback preference for the mix with fallback to preserved originals;
- persistent on-device transcription with WhisperKit 1.0.0;
- bounded long-recording transcription with VAD and word timestamps;
- persistent `transcript.json` with atomic publication and restart recovery;
- local speaker diarization through SpeakerKit 1.0.0;
- Pyannote v3 segmenter/embedder + v4 PLDA clustering resources downloaded at runtime;
- speaker assignment aligned onto existing transcript timestamps without re-transcribing or rewriting source audio;
- durable speakers, per-segment `speakerID` and diarization metadata;
- diarization retry/cancellation semantics that preserve the previous valid transcript;
- minimal transcript UI with `Identify Speakers`, progress, cancel, re-run and `Speaker 1`, `Speaker 2`, ... labels.

## Transcription architecture

```text
managed recording audio
→ choose transcription source
→ prepare large-v3 Core ML model + tokenizer
→ load <= 300 s interval
→ 16 kHz mono Float samples
→ WhisperKit VAD + word timestamps
→ merge interval results
→ transcript.json
```

For a System + Microphone recording, transcription requires the derived `conversationMix`. Bardo does not silently substitute a single original as the complete conversation.

## Diarization architecture

```text
existing transcript.json
+
managed conversation audio
→ resolve/download SpeakerKit models
→ load Pyannote v3 + PLDA v4 pipeline
→ local SpeakerKit diarization
→ timestamped speaker intervals
→ word/segment overlap alignment
→ Speaker objects + TranscriptSegment.speakerID
→ atomic transcript.json update
```

Diarization is additive over the Phase 5 transcript. It does not run Whisper again, alter transcript text, or modify managed audio. If diarization fails or is cancelled, the previously persisted transcript remains authoritative.

Speaker labels are ordered by first appearance for the UI. A transcript segment with no temporal overlap remains unassigned. A segment containing multiple real speakers receives the dominant overlap speaker in Phase 6; transcript turn splitting/restructuring belongs to later transcript UX work.

For System + Microphone recordings, diarization uses the same strict `conversationMix` requirement as transcription.

## SpeakerKit memory contract

Unlike the bounded Phase 5 transcription pipeline, SpeakerKit 1.0.0's public diarization API accepts one complete 16 kHz mono `[Float]` array and performs global clustering for one call. Bardo therefore does not independently diarize arbitrary chunks, because speaker cluster IDs would not be safely comparable between separate calls without a second reconciliation system.

The raw Float allocation is approximately:

```text
64 KB/s
≈ 230 MB for one hour of audio
```

plus model/tensor memory. Bardo scopes that full-session buffer to inference and does not intentionally retain a second full copy. Real long-session memory, thermal behavior and throughput remain physical `PARTIAL` evidence.

## Models and dependency boundary

`project.yml` pins `argmaxinc/argmax-oss-swift` exactly to **1.0.0** and links the direct products:

- `WhisperKit`
- `SpeakerKit`

Bardo does not link the `ArgmaxOSS` umbrella product or `TTSKit` in Phase 6.

Whisper resources live under:

```text
Application Support/Bardo/Models/WhisperKit/
```

Speaker resources live under:

```text
Application Support/Bardo/Models/SpeakerKit/
```

Both are downloaded at runtime rather than bundled with the app. See `THIRD_PARTY_NOTICES.md` for the preserved source-code license notice and model-artifact distribution caveat.

## Persistence

The recording manifest remains write schema **3**. Transcript write schema remains **1**.

```text
Application Support/Bardo/Library/<recording-uuid>/
├── manifest.json       # Recording schema V3
├── transcript.json     # Transcript schema V1
└── audio/...
```

Phase 6 reuses the existing durable `Speaker` / `TranscriptSegment.speakerID` structure and adds optional diarization metadata. Phase 5-style transcript V1 documents without that metadata remain readable.

Bardo keeps the recovery policy:

`preserve → detect → inform → continue`

A failed/cancelled diarization does not damage a valid transcript or recording. Successful speaker enrichment is published through the same atomic TranscriptStore replacement path.

## Permissions and privacy

The generated application configuration includes:

- `NSMicrophoneUsageDescription`;
- `NSScreenCaptureUsageDescription`;
- Hardened Runtime configuration;
- `com.apple.security.device.audio-input`;
- `com.apple.security.network.client` for runtime model downloads.

Transcription and diarization run locally after their model resources are present. Bardo does not send recording audio to an application-owned transcription or diarization backend.

CI builds unsigned, so normally signed entitlement/TCC behavior and real model downloads remain interactive smoke evidence rather than automated claims.

## Tests

The Phase 6 production/reviewer head passed **103 XCTest cases with 0 failures** in GitHub Actions CI #106 on macOS 15.7.7 Apple Silicon, Xcode 16.4 and Swift 6.1.2.

Automated coverage includes all inherited Phase 0–5 regressions plus speaker alignment, first-appearance ordering, raw-transcript preservation, unassigned temporal gaps, Phase 5 transcript compatibility, speaker metadata persistence, failure/cancellation preservation, failed re-diarization preservation, fresh Library reconstruction and dual-source mix enforcement.

CI compiles the real SpeakerKit production boundary but intentionally does not download the production SpeakerKit models or claim real multi-speaker quality/performance. Those remain documented as `PARTIAL` in `PROJECT_STATE.md`.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI: SwiftUI / AppKit lifecycle bridge
- Capture/audio: AVFoundation / AVFAudio / ScreenCaptureKit
- Transcription: WhisperKit 1.0.0
- Diarization: SpeakerKit 1.0.0
- Project generator: XcodeGen
- Recording manifest write schema: 3
- Transcript write schema: 1

## Explicitly out of scope

Phase 6 does not implement speaker naming/editing, transcript turn restructuring, summaries, live transcription/diarization, waveform work, export work or other Phase 7+ functionality.

See `PROJECT_STATE.md` for exact certification evidence, reviewer repairs, memory limitations, recovery invariants, physical evidence debt and the next permitted phase.
