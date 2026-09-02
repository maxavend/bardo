# Bardo Project State

## Current stabilization scope

Bardo is a native macOS 15+ SwiftUI app with Swift 6 concurrency. The current stabilization work covers local transcription, Bardo-owned model storage, bounded model repair, SpeakerKit diarization and naming, text-only Qwen Meeting Minutes, observable XCTest diagnostics and mounted Test/Latest DMG workflows.

The stabilization branch is intentionally not merged automatically. A fresh CI run for the final HEAD is required before calling the branch ready or promoting an artifact.

## Model architecture

```text
audio
 ├─ Instant → Parakeet TDT 0.6B v3 / FluidAudio 0.15.6
 └─ Balanced (default) or Maximum Accuracy → WhisperKit large-v3 Turbo / large-v3
       ↓
    Transcript
       ↓ optional
    SpeakerKit / Pyannote diarization + speaker names/previews
       ↓
    final transcript text
       ↓
    Qwen3.5-0.8B-MLX-4bit → Meeting Minutes
```

Qwen is never part of ASR and never receives audio. Long transcript generation uses conservative extraction/synthesis chunking. The model manager exposes Not Installed, Downloading, Preparing/Optimizing, Installed and Failed states.

## Storage ownership

All runtime model ownership is below:

```text
~/Library/Application Support/Bardo/Models/
├── whisper-balanced/
├── whisper-maximum-accuracy/
├── parakeet/
├── speaker-kit/
└── qwen/
```

Parakeet does not use `~/Library/Application Support/FluidAudio` as a readiness source. Qwen production loading supplies an explicit fixed `HubCache` rooted in Bardo's Qwen directory. A global Hugging Face cache does not make Qwen Installed. Reset only removes the selected child of Bardo's model root.

## Recovery contract

Every model operation follows download → load → bounded repair:

- a complete private cache is loaded first;
- a load failure for an already-present cache marks it corrupt, removes only that private model directory, recreates the engine and retries one download/load;
- a first-download network failure is surfaced without destructive retry;
- cancellation preserves valid data and performs no repair;
- no operation has an unbounded retry loop.

SpeakerKit discards a cached in-memory engine after repair. Warm-up is not allowed to publish Ready unless the private models load successfully. Transcript edits and speaker names continue to use the existing atomic TranscriptStore boundary.

## CI and DMG evidence

The workflows are:

- `CI`: XcodeGen, Debug build, visible `xcode-test.log`, failure summaries and uploaded XCTest log;
- `Build Test DMG`: checks out `github.sha`, runs the same DMG verifier for the test image and uploads DMG/checksum/mounted-validation/XCTest artifacts;
- `Build Latest DMG`: checks out `github.sha`, runs the same verifier for the latest image and uploads the same artifacts.

The shared verifier builds Release ARM64, validates the app and privacy metadata, ad-hoc signs it, creates the image, attaches it read-only, asserts `Bardo.app` and the `/Applications` alias, validates the mounted bundle/signature, detaches in a trap, runs `hdiutil verify`, and writes a checksum sidecar containing both the image hash and `github.sha`.

The local fixture at `.github/scripts/test-verify-dmg.sh` proves that an image without `Bardo.app` is rejected. CI evidence is commit-specific: if HEAD changes, all gates must be rerun.

## Physical validation still required

CI does not download production model artifacts or prove inference quality. A real Apple Silicon Mac still needs to validate first-use Parakeet/WhisperKit/SpeakerKit/Qwen downloads, speaker preview playback, visual naming/edit flows, long-session memory/thermal behavior, microphone/system-audio TCC permissions and first-launch behavior of the ad-hoc, non-notarized DMG. These are evidence limitations, not substitutes for the automated bundle and mounted-image checks.

The detailed manual procedure is in `TESTING.md`.
