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

## Persistence

Managed source audio stays inside the recording store. Transcript edits and speaker names are saved atomically through `TranscriptStore`; original recognition text and timing evidence remain available when a segment is manually corrected.

## CI and DMG evidence

CI generates the project from `project.yml`, verifies capture/transcription entitlements, verifies `AppIcon` is the configured asset-catalog app icon, builds the app, checks the compiled asset catalog, and runs XCTest.

The DMG workflows continue to validate bundle structure and signing separately.

## Physical validation still required

A real Apple Silicon Mac should validate first-run WhisperKit/SpeakerKit download and load behavior, real transcription quality, speaker identification, transcript playback alignment, microphone/system-audio permissions, long-session memory/thermal behavior, and first-launch behavior of development DMGs.
