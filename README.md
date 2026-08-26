# Bardo

Bardo is a privacy-first native macOS app for capturing, managing, transcribing and understanding conversations locally. Phases 0–6 are integrated on `main`; **Phase 7 — Transcript UX** is implemented on `feat/phase-7-transcript-ux` in PR #9.

Bardo can import audio, record microphone-only conversations, capture system audio through the native macOS picker, capture system + microphone as independent originals with a derived conversation mix, create persistent on-device transcripts with WhisperKit, identify speakers locally with SpeakerKit, and present the result as an editable timestamped conversation.

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
- conversational transcript turns with speaker labels and timestamp seek controls;
- transcript search and copy-all;
- persistent speaker naming;
- non-destructive transcript text corrections that preserve Whisper's original text, word timestamps and timing evidence;
- restore-original behavior for corrected transcript segments;
- protective confirmation before re-transcription would replace manual edits/names;
- protective confirmation before re-diarization would replace named speaker clusters.

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

Diarization does not run Whisper again or modify managed audio. If diarization fails or is cancelled, the previously persisted transcript remains authoritative. Manual text corrections survive re-diarization because speaker alignment mutates the existing transcript rather than rebuilding its text; manually assigned speaker names are intentionally not carried to newly clustered speakers because new cluster identities may represent different people.

For System + Microphone recordings, diarization uses the same strict `conversationMix` requirement as transcription.

## Transcript UX and editing contract

Phase 7 keeps generated evidence separate from human corrections.

Each `TranscriptSegment` retains its original Whisper text and optional word-level timestamps. A human correction is stored separately as optional `editedText`:

```text
Whisper text + word timings     # preserved evidence
          +
optional editedText             # human-readable override
          ↓
       displayText
```

`Transcript.text`, on-screen turns, search and copy use `displayText`. Clearing an edit restores the original generated text without reconstructing timestamps.

Speaker naming uses the existing optional `Speaker.name`. Blank names restore the automatic `Speaker 1`, `Speaker 2`, ... presentation.

Edits are persisted through the existing `TranscriptStore` same-directory temporary file + atomic rename boundary. UI state changes only after persistence succeeds.

Re-transcription creates a new generated transcript, so Bardo requires confirmation when the current transcript contains manual corrections or named speakers. Re-diarization may produce different clusters, so Bardo requires confirmation before replacing manually named speakers instead of guessing that old and new cluster ordinals identify the same people.

## SpeakerKit memory contract

Unlike the bounded transcription pipeline, SpeakerKit 1.0.0's public diarization API accepts one complete 16 kHz mono `[Float]` array and performs global clustering for one call. Bardo therefore does not independently diarize arbitrary chunks, because speaker cluster IDs would not be safely comparable between separate calls without a second reconciliation system.

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

Bardo does not link the `ArgmaxOSS` umbrella product or `TTSKit`.

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

Phase 7 adds optional `TranscriptSegment.editedText` and uses the already durable optional `Speaker.name`. The new field is additive/optional, so Phase 5/6 Transcript V1 documents remain readable and no schema bump is required.

Bardo keeps the recovery policy:

`preserve → detect → inform → continue`

Failed edit persistence leaves the previously valid transcript authoritative. Transcription/diarization and manual edit operations are mutually excluded in the Library view model.

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

The Phase 7 production/reviewer head `61021ef2413b8fe1b6503642d7a595526f775207` passed **109 XCTest cases with 0 failures** in GitHub Actions CI #114 on macOS 15.7.7 Apple Silicon, Xcode 16.4 and Swift 6.1.2.

Phase 7 coverage includes all inherited Phase 0–6 regressions plus legacy transcript decoding without `editedText`, non-destructive edit round trips, original word/timing preservation, speaker-name persistence, fresh-view-model reconstruction, restore-original behavior, empty-edit rejection and manual-change detection used by replacement confirmation UX.

CI compiles the real WhisperKit/SpeakerKit production boundaries but intentionally does not download production models or claim real transcription/diarization quality. Visual interaction quality, real model downloads, long-session resource behavior and inherited TCC/system-audio physical smoke remain documented as `PARTIAL` in `PROJECT_STATE.md`.

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

Phase 7 does not add summaries/LLM processing, waveform UI, live transcription/diarization, export, custom speaker-cluster reconciliation or other Phase 8+ functionality.

See `PROJECT_STATE.md` for exact certification evidence, reviewer repairs, recovery invariants, physical evidence debt and phase boundaries.
