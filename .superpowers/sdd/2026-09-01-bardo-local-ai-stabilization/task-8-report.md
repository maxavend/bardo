# Task 8 report — Stabilize persistence and UI task ownership

## Scope

Task 8 integrates the existing model services and transcript abstractions without replacing them.

- `TranscriptionSetupCoordinator` now owns the setup task, exposes cancellation, reaches a terminal `cancelled` state, supports retry, and offers `Reset & Download Again` for Bardo-owned Whisper/SpeakerKit storage.
- `TranscriptionSetupView` and launch wiring expose the terminal actions and never keep a cancelled operation in a downloading presentation.
- `LibraryViewModel` owns transcription, diarization, and Meeting Minutes tasks. Each operation clears its task reference and progress in `defer`; cancellation preserves the last valid persisted result and failures publish actionable errors.
- Speaker naming is requested only after a successful diarization result with two or more speakers. The existing `SpeakerNamingPolicy` remains the single business rule.
- `SpeakerNamingSheet` supports per-speaker names and representative preview playback through the existing single-player controller.
- `MeetingMinutesView` is shown only for a selected recording with a transcript and starts the existing text-only generator; it never passes audio to Qwen.
- Transcript edits and speaker names remain persisted through `TranscriptStore`, preserving original segment text, timing, words, and `editedText` separation.

## Tests

Added `BardoTests/ModelTaskLifecycleTests.swift` covering task cleanup after transcription success/failure/cancellation, Meeting Minutes gating and persistence, and post-diarization naming requests. Existing `TranscriptUXTests` and `SpeakerNamingPolicyTests` remain in place for edit/name invariants and the 0/1/2+ speaker policy.

`xcodegen generate` completed successfully. The focused XCTest command was started with Xcode access, but SwiftPM dependency resolution produced no progress output and was stopped at the user's request to avoid a long build/test run. No full-suite result is claimed for this commit.

## Commit

Planned commit: `feat: stabilize model tasks and transcript UX`
