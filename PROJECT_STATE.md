# Bardo Project State

## Current scope

Bardo is a native macOS 15+ SwiftUI app using Swift 6 concurrency. The active branch focuses on private local transcription, optional speaker identification, transcript editing/search, recording reliability, and a native macOS product experience.

There is no generative meeting-minutes runtime in the current product scope.

## Processing architecture

```text
audio
 └─ Whisper Large v3 Turbo / WhisperKit 1.1.0
       ↓
    Transcript with word timestamps
       ↓ optional
    SpeakerKit / Pyannote diarization
       ↓
    speaker names + editable transcript
```

## Runtime model ownership

Bardo owns the local resources it uses under:

```text
~/Library/Application Support/Bardo/Models/
├── whisper-turbo/
└── speaker-kit/
```

A global cache does not make a Bardo resource ready. Voice setup validates Bardo's private cache, downloads resources when absent, prepares them locally, and keeps the private cache authoritative.

## Interface

The main window follows Mail, Notes and Voice Memos: Library filters in the sidebar, a keyboard-driven list, the selected conversation and an optional inspector. One toolbar search field covers the whole Library (accent-insensitive, with snippets) and highlights matches in the transcript. Menus, toolbar actions and states (loading, errors, empty filters, untranscribed and failed conversations) are native. Debug builds include a visual review that drives the real windows and captures them (see `TESTING.md`).

## Persistence

Managed source audio stays inside the recording store. Transcript edits and speaker names are saved atomically through `TranscriptStore`; original recognition text and timing evidence remain available when a segment is manually corrected.

## Reliability guarantees

- Capture is crash-safe: fragmented M4A for system/meeting tracks, CAF linear PCM for the microphone (compressed to AAC on stop, lossless fallback).
- Interrupted captures keep `capture.json` and can be recovered into the Library with their title and sources. Captures without audio are discarded.
- Publication moves staged audio into the Library and returns it to staging if publication fails.
- Manifests and transcripts are fsynced before their atomic rename; Bardo's data is owner-only.
- The Library is never locked behind model setup; setup that is running, paused, failed or missing models is shown in a banner.
- Whisper and SpeakerKit downloads and loads are single-flight; models are not unloaded during a transcription and cannot be removed while in use. Cancelling speaker identification returns immediately.
- Library jobs start atomically, recording updates do not overwrite each other, edits cannot race model work, and reloading the Library does not interrupt playback.

## Verification evidence

- XCTest: 229 tests, 0 failures (3 opt-in tests skipped: two real-model checks and the design-review seed), on Xcode 27 / macOS 27; CI builds and tests with Xcode 26.6.
- Real models (`RealModelEndToEndTests`, Whisper large-v3 Turbo + SpeakerKit, MacBook Air with 16 GB):
  - 25 s two-voice Spanish dialogue: all four turns, two speakers correctly alternating; about 4.5 s to transcribe once the model is loaded.
  - 187 s dialogue (beyond one 120 s loading chunk): all 24 turns in order and 23/23 speaker alternations in every run; 16–20 s to transcribe, under 1 s to identify speakers.
- Those checks found two ways transcription silently dropped speech, both fixed and pinned by unit tests:
  - a decoder vocabulary prompt made Whisper skip the opening of each window (a 25 s dialogue kept only its last 12 s);
  - Whisper's default compression-ratio check (2.4) treated repetitive conversation as a loop, and the temperature fallback then dropped 2–13 of 24 turns at random. The threshold is now 3.5.
- An independent review of the full diff found recovery paths that could delete unpublished audio and shared-download cancellation crossing between setup and transcription; both were fixed with regression tests.
- During heavy diagnostic runs the test host exited three times without a crash or memory report while running the long real-model test; it did not reproduce in seven later runs, including the same sequence.

## CI and DMG evidence

CI generates the project from `project.yml`, verifies capture/transcription entitlements, verifies `AppIcon` is the configured asset-catalog app icon, builds the app, checks the compiled asset catalog, and runs XCTest.

The DMG workflows continue to validate bundle structure and signing separately.

## Releases

Version 1.0.0 (build 1) is the first release. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the only source of the app's version. Pushing a `v*` tag runs the Release workflow, which checks the tag against the version, runs the tests, builds and verifies `Bardo-<version>.dmg` and attaches it with its SHA-256 to a draft GitHub release. Every push to `main` also builds `Bardo-Latest.dmg` as a workflow artifact.

## Physical validation still required

Automated tests cover the capture writers with synthetic audio and the real models with synthetic speech. A real Apple Silicon Mac should still validate: microphone and Screen & System Audio Recording permissions, a real meeting recording, force-quitting during a recording and recovering it, first-run download on a clean install and offline, multi-hour memory/thermal behavior, and first launch of development DMGs.

## Not yet addressed

- App Sandbox is not enabled. Enabling it needs security-scoped bookmarks for imports and a migration of existing data into the container.
- Builds are ad-hoc signed; Developer ID signing and notarization are required for distribution.
- Much of the interface is written directly in Spanish; English UI strings are incomplete.
