# Bardo

Bardo is a privacy-first native macOS app for capturing, managing, transcribing and understanding conversations locally. The local-AI stabilization work is kept on the active stabilization branch until its fresh CI and DMG gates are reviewed; it is not merged automatically.

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
- persistent on-device local transcription;
- one local transcription backend: WhisperKit Whisper Large v3 Turbo with incremental loading, VAD, concurrency and word timestamps;
- persistent `transcript.json` with atomic publication and restart recovery;
- local speaker diarization through SpeakerKit;
- private Pyannote v3 segmenter/embedder + v4 PLDA clustering resources prepared through SpeakerKit during first-run setup;
- word-level speaker assignment and conversational turn reconstruction without re-transcribing or rewriting source audio;
- durable speakers, per-segment `speakerID` and diarization metadata;
- conversational transcript turns with speaker labels and timestamp seek controls;
- transcript search and copy-all;
- persistent speaker naming;
- non-destructive transcript text corrections that preserve Whisper's original text, word timestamps and timing evidence;
- restore-original behavior for corrected transcript segments;
- protective confirmation before re-transcription would replace manual edits/names;
- protective confirmation before re-diarization would replace named speaker clusters.
- optional local Meeting Minutes generated from completed transcript text with LFM2.5 1.2B MLX 4-bit;
- representative speaker voice previews, with only one preview playing at a time;
- explicit local model states, cancellation and recovery; Meeting Minutes downloads its model during first-run setup when it is not bundled.

## Transcription architecture

```text
managed recording audio
→ WhisperKit Whisper Large v3 Turbo
→ incremental long-form loading with bounded buffers
→ 16 kHz mono Float samples
→ WhisperKit VAD + concurrent workers + word timestamps
→ transcript.json
```

For a System + Microphone recording, transcription requires the derived `conversationMix`. Bardo does not silently substitute a single original as the complete conversation.

## Diarization architecture

```text
existing transcript.json
+
managed conversation audio
→ use private SpeakerKit models prepared during first-run setup
→ load Pyannote v3 + PLDA v4 pipeline
→ local SpeakerKit diarization
→ timestamped speaker intervals
→ word overlap alignment
→ conversational turn builder
→ Speaker objects + TranscriptSegment.speakerID
→ atomic transcript.json update
```

Diarization does not run Whisper again or modify managed audio. If diarization fails or is cancelled, the previously persisted transcript remains authoritative. Manual text corrections survive re-diarization because speaker alignment mutates the existing transcript rather than rebuilding its text; existing speaker IDs and names are retained by first appearance where possible.

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

Unlike the bounded transcription pipeline, SpeakerKit's public diarization API accepts one complete 16 kHz mono `[Float]` array and performs global clustering for one call. Bardo therefore does not independently diarize arbitrary chunks, because speaker cluster IDs would not be safely comparable between separate calls without a second reconciliation system.

The raw Float allocation is approximately:

```text
64 KB/s
≈ 230 MB for one hour of audio
```

plus model/tensor memory. Bardo scopes that full-session buffer to inference and does not intentionally retain a second full copy. Real long-session memory, thermal behavior and throughput remain physical `PARTIAL` evidence.

## Models, ownership and recovery

`project.yml` pins the production packages and links only the products Bardo uses:

- `WhisperKit`
- `SpeakerKit`
- MLX/Hugging Face products for local LFM2.5 Meeting Minutes

Bardo does not link the `ArgmaxOSS` umbrella product or `TTSKit`. The model manager owns these private roots:

```text
Bardo.app/Contents/Resources/Models/
├── manifest.json
├── WhisperKit/large-v3-v20240930_turbo_632MB/
└── SpeakerKit/

Bardo.app/Contents/Resources/Models/Minutes/
└── LFM2.5-1.2B-Instruct-4bit/       # optional

Application Support/Bardo/Models/meeting-minutes/
└── LFM2.5-1.2B-Instruct-4bit/       # downloaded during first-run setup
```

Voice models are downloaded during first-run setup into Bardo’s private Application Support model root and validated before loading. Bardo owns only the Whisper Turbo and SpeakerKit roots; it does not use or count a global Hugging Face cache. Legacy Whisper/Parakeet directories are removed only during the one-time migration; Qwen and meeting-minutes data remain private and untouched.

Voice models are not required in the DMG. The first setup downloads the pinned models, reports progress, and reuses them locally on subsequent runs. Settings retains an explicit retry/install action for recovery. See `THIRD_PARTY_NOTICES.md` for upstream license and model-artifact notices.

LFM2.5 is not an ASR backend. It receives only the completed transcript, available speaker names and minimal context, then generates Meeting Minutes through conservative MAP/REDUCE/RENDER stages. The model is resolved from a Bardo-managed local directory first, with a bundled Resources/Models/Minutes snapshot accepted when present. If neither exists, Bardo downloads the pinned public snapshot during first-run setup into `Application Support/Bardo/Models/meeting-minutes`, validates the required files, and reuses it locally; it never uses the global Hugging Face cache.

For local development, an offline snapshot can still be staged explicitly before building:

```text
bash .github/scripts/fetch-minutes-model.sh --replace
xcodegen generate
```

The fetch script stages the snapshot under `Bardo/Resources/Models/Minutes/` for the local build and those large files are ignored by Git. A distributed app does not require that resource: the first-run setup path stores the model under Application Support instead.

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
- `com.apple.security.network.client` for local model/minutes integrations that may need network access elsewhere in the product.

Transcription and diarization run locally after their model resources are present. Bardo does not send recording audio to an application-owned transcription or diarization backend.

CI builds the Release app unsigned and then applies an ad-hoc signature for DMG validation. The resulting DMG is mounted read-only and checked for `Bardo.app`, the `/Applications` alias, bundle metadata and signature before upload. Ad-hoc signing is not Developer ID signing and is not notarization; first-launch approval and TCC behavior remain physical macOS evidence.

## Tests

The current CI workflow covers the inherited regression suite plus local-AI model ownership, recovery, Meeting Minutes, speaker naming/preview and task-lifecycle tests. A fresh run is required for each final HEAD; this documentation does not claim a pass from an earlier commit.

CI compiles the real WhisperKit, SpeakerKit and MLX production boundaries but intentionally does not claim real transcription/diarization/minutes quality. Visual interaction quality, first-run model download/load, long-session resource behavior and inherited TCC/system-audio physical smoke remain physical evidence in `PROJECT_STATE.md`.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI: SwiftUI / AppKit lifecycle bridge
- Capture/audio: AVFoundation / AVFAudio / ScreenCaptureKit
- Transcription: WhisperKit Whisper Large v3 Turbo
- Diarization: SpeakerKit / Pyannote resources
- Meeting Minutes: LFM2.5-1.2B-Instruct-4bit via MLXSwiftLM
- Project generator: XcodeGen
- Recording manifest write schema: 3
- Transcript write schema: 1

## Evidence boundaries

CI can prove project generation, compilation, unit tests, bundle checks, ad-hoc signing and mounted DMG contents. It does not download production models or prove transcription/diarization quality. Real model generation, long-session memory/thermal behavior, audio previews, visual UX and microphone/system-audio TCC permissions require a physical Apple Silicon Mac smoke test. The DMG workflows must be rerun for every new HEAD; an artifact from an earlier commit is not evidence for a later one.

See `PROJECT_STATE.md` for exact certification evidence, reviewer repairs, recovery invariants, physical evidence debt and phase boundaries.
