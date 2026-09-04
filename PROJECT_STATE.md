# Bardo Project State

## Current stabilization scope

Bardo is a native macOS 15+ SwiftUI app with Swift 6 concurrency. The current stabilization work covers private on-demand Whisper Turbo transcription, SpeakerKit diarization and naming, text-only Qwen Meeting Minutes, observable XCTest diagnostics and mounted Test/Latest DMG workflows.

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
    final transcript text
       ↓
    Qwen3.5-0.8B-MLX-4bit → Meeting Minutes
```

Qwen is never part of ASR and never receives audio. Long transcript generation uses conservative extraction/synthesis chunking. The model manager exposes Not Installed, Downloading, Preparing/Optimizing, Installed and Failed states.

## Storage ownership

Qwen remains the only user-managed model; Bardo-managed voice models live in private Application Support storage:

```text
~/Library/Application Support/Bardo/Models/
├── whisper-turbo/large-v3-v20240930_turbo_632MB/
├── speaker-kit/
└── meeting-minutes/
```

Voice models download on demand into their private roots and are verified by the SDK/file checks before loading. Qwen production loading supplies an explicit fixed `HubCache` rooted in Bardo's Qwen directory. A global Hugging Face cache does not make any managed model Installed. The one-time migration removes only the exact legacy Whisper/Parakeet directories and never touches Qwen or meeting-minutes data.

## Recovery contract

Voice setup follows validate private cache → download when absent → load → keep the private cache authoritative. An invalid existing voice cache is removed and downloaded once again; cancellation or a first download failure does not trigger destructive retries. Qwen keeps its existing private lifecycle and bounded recovery.

Warm-up is not allowed to publish Ready unless the downloaded models load successfully. Transcript edits and speaker names continue to use the existing atomic TranscriptStore boundary.

## CI and DMG evidence

The workflows are:

- `CI`: XcodeGen, Debug build, visible `xcode-test.log`, failure summaries and uploaded XCTest log;
- `Build Test DMG`: checks out `github.sha`, runs the same DMG verifier for the test image and uploads DMG/checksum/mounted-validation/XCTest artifacts;
- `Build Latest DMG`: checks out `github.sha`, runs the same verifier for the latest image and uploads the same artifacts.

The shared verifier builds Release ARM64, validates the app and privacy metadata, ad-hoc signs it, creates the image, attaches it read-only, asserts `Bardo.app` and the `/Applications` alias, validates the mounted bundle/signature, detaches in a trap, runs `hdiutil verify`, and writes a checksum sidecar containing both the image hash and `github.sha`.

The local fixture at `.github/scripts/test-verify-dmg.sh` proves that an image without `Bardo.app` is rejected. CI evidence is commit-specific: if HEAD changes, all gates must be rerun.

## Physical validation still required

CI does not claim production model quality. A real Apple Silicon Mac still needs to validate first-run WhisperKit/SpeakerKit downloads and loading, speaker preview playback, visual naming/edit flows, long-session memory/thermal behavior, microphone/system-audio TCC permissions and first-launch behavior of the ad-hoc, non-notarized DMG. These are evidence limitations, not substitutes for the automated mounted-image checks.

The detailed manual procedure is in `TESTING.md`.
