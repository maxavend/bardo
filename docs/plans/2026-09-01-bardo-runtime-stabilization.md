# Bardo runtime and model stabilization plan

## Goal
Ship a reliable Apple Silicon macOS build and DMG where model installation state is owned by Bardo, Parakeet cannot hang indefinitely on stale or partial caches, transcription modes behave consistently, speaker naming appears only when useful, and local Qwen meeting minutes remain isolated from ASR.

## Scope

1. Parakeet model ownership and validation
   - Move Instant/Parakeet storage from FluidAudio's shared default cache into `Application Support/Bardo/Models/Parakeet`.
   - Treat the model as installed only when FluidAudio validates the complete v3 asset set.
   - Never delete or mutate FluidAudio's global cache from Bardo.
   - If Bardo's private cache is partial/corrupt, remove that private cache and retry a clean download once.
   - Ensure cancellation/error paths release the model manager and report failure rather than leaving UI in a loading state.

2. Transcription quality contract
   - Instant = Parakeet TDT 0.6B v3.
   - Balanced (default) = Whisper large-v3 Turbo.
   - Maximum Accuracy = Whisper large-v3.
   - Preserve the shared Transcript domain so karaoke, seeking, diarization and editing are engine-independent.

3. Speaker naming
   - Offer the naming sheet automatically only when diarization finds 2 or more speakers.
   - Keep 10-second representative clips and a single active preview player.
   - Persist names on existing speaker IDs so transcript/karaoke/minutes see the same identities.

4. Meeting minutes
   - Keep Qwen 3.5 0.8B MLX as the dedicated transcript-to-minutes engine.
   - Qwen receives text/transcript evidence only and performs no audio transcription.
   - Keep generation local, bounded for long transcripts, and persistence non-destructive.

5. Reliability and packaging
   - Fix the current failing unit-test gate before declaring the branch releasable.
   - Verify Debug build, unit tests, Release arm64 build, bundle validation, DMG creation and `hdiutil verify` through GitHub Actions.
   - Keep macOS 27 toolbar compatibility paths intact while avoiding new custom chrome where native SwiftUI/AppKit behavior is safe.

## Verification matrix

- Fresh Mac/Bardo state: no model is reported installed until Bardo owns a complete validated model directory.
- Existing FluidAudio global Parakeet cache: Bardo does not claim it as its own installation and does not delete it.
- Interrupted Parakeet download: next attempt repairs/re-downloads Bardo's private cache and exits loading state on failure.
- Installed Parakeet: warm-up and transcription load from Bardo's private cache without network access.
- Balanced and Maximum Accuracy continue using their existing Bardo-private WhisperKit folders.
- One speaker: no automatic naming prompt.
- Two or more speakers: naming prompt exposes one <=10s sample per speaker and only one sample plays at a time.
- Qwen minutes: generation operates only on a persisted transcript and does not load an ASR engine.
- CI + Test DMG workflows are green before release readiness is claimed.
