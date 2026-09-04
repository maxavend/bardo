# Bardo Project State

## Current stabilization scope

Bardo is a native macOS 15+ SwiftUI app with Swift 6 concurrency. The active stabilization branch covers private Whisper Turbo transcription, SpeakerKit diarization and naming, LFM2.5 Meeting Minutes, observable XCTest diagnostics and mounted Test/Latest DMG workflows.

The stabilization branch is intentionally not merged automatically. A fresh CI run for the final HEAD is required before calling the branch ready or promoting an artifact.

## Model architecture

```text
audio
 └─ Whisper Large v3 Turbo / WhisperKit 1.1.0
       ↓
    Transcript with word timestamps
       ↓ optional
    SpeakerKit / Pyannote diarization + speaker names/previews
       ↓
    completed transcript text
       ↓
    LFM2.5-1.2B-Instruct-4bit / MLXSwiftLM
       ↓
    MAP evidence → REDUCE semantic state → RENDER Meeting Minutes
```

LFM2.5 is text-only. It never receives source audio, audio URLs or sample buffers.

## Meeting Minutes runtime contract

Production Meeting Minutes uses:

```text
mlx-community/LFM2.5-1.2B-Instruct-4bit
revision 125e006d991147f3b432249d1bdf0821987f12b0
```

The revision is immutable in production. Every downloaded/staged snapshot contains a `.bardo-model-revision` marker and the resolver accepts only a complete snapshot whose marker matches the pinned revision.

A complete set of files is not enough for Bardo to publish the model as Ready. First-run setup must:

1. resolve or download the exact pinned snapshot;
2. load the real MLX `ModelContainer` and tokenizer;
3. execute a short local generation health check;
4. persist the runtime-ready marker only after that generation succeeds.

The verified container stays warm for subsequent generation and is unloaded after an idle timeout. A failed health check clears runtime readiness instead of publishing a false Installed state.

Qwen is no longer part of the production runtime. An old private `Models/qwen/` folder may remain from previous builds; Settings can detect it and offers explicit removal. Bardo never deletes that legacy folder automatically.

## Storage ownership

```text
~/Library/Application Support/Bardo/Models/
├── whisper-turbo/
├── speaker-kit/
├── meeting-minutes/
│   └── LFM2.5-1.2B-Instruct-4bit/
└── qwen/                         # optional legacy data; not used
```

Runtime model ownership is private to Bardo. A global Hugging Face cache does not make a Bardo model Ready.

## Recovery contract

Voice setup follows validate private cache → download when absent → load → keep the private cache authoritative.

Meeting Minutes follows validate exact revision → download when absent/outdated → load MLX runtime → health-check local generation → publish Ready. Reset removes only the selected current model. Legacy Qwen removal is a separate explicit Settings action.

Transcript edits and speaker names continue to use the existing atomic TranscriptStore boundary.

## CI and DMG evidence

The workflows are:

- `CI`: XcodeGen, Debug build, visible `xcode-test.log`, failure summaries and uploaded XCTest log;
- `Build Test DMG`: checks out `github.sha`, runs the shared DMG verifier and uploads DMG/checksum/mounted-validation/XCTest artifacts;
- `Build Latest DMG`: checks out `github.sha`, runs the same verifier and uploads the same evidence.

CI evidence is commit-specific: if HEAD changes, all gates must be rerun.

## Physical validation still required

Automated tests cover the model revision/readiness contract, prompt pipeline, persistence and legacy cleanup boundaries, but they do not certify real Meeting Minutes quality.

A real Apple Silicon Mac still needs to validate first-run WhisperKit/SpeakerKit/LFM2.5 download and load behavior, the LFM health check, first-token latency, complete Spanish Meeting Minutes output, speaker preview playback, long-session memory/thermal behavior, microphone/system-audio TCC permissions and first-launch behavior of the ad-hoc, non-notarized DMG.

The detailed manual procedure is in `TESTING.md`.
