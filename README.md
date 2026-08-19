# Bardo

Bardo is a privacy-first native macOS app for managing conversations locally. The repository is currently implementing **Phase 2 — Audio Import**: real audio files can be validated, copied into Bardo-managed storage, reconstructed after restart, inspected for technical metadata, and played from the managed copy.

Phase 2 intentionally contains **zero AI**. There is no transcription, diarization, microphone capture, or system-audio capture yet.

## Development requirements

- macOS 15 or later
- Xcode 16 or later with the Swift 6 toolchain
- XcodeGen 2.46.0 or later

CI validates the project on macOS 15 with Xcode 16.4.

```sh
brew install xcodegen
xcodegen generate
```

`project.yml` remains the source of truth; `Bardo.xcodeproj` is generated and not committed.

## Build and test

```sh
xcodebuild \
  -project Bardo.xcodeproj \
  -scheme Bardo \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Bardo.xcodeproj \
  -scheme Bardo \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Current functionality

Bardo provides:

- native SwiftUI macOS application;
- `NavigationSplitView` Library;
- native file picker and drag & drop audio import;
- managed local copies for successful imports;
- supported import extensions: `.m4a`, `.mp3`, `.wav`, `.flac`, `.aac`, `.aiff`;
- audio-content validation through AVFoundation rather than trusting only the extension;
- persisted duration, codec label, sample rate, and channel count;
- native play, pause, seek, current-position, and total-duration controls;
- schema-versioned persistence and per-recording recovery isolation.

Importing the same external file twice intentionally creates two independent recordings. Phase 2 has no hash-deduplication system.

## Managed audio storage

The live store resolves its Application Support location through `FileManager` and currently uses this conceptual layout:

```text
~/Library/Application Support/Bardo/Library/
└── <recording-uuid>/
    ├── manifest.json
    └── audio/
        └── <audio-asset-uuid>.<ext>
```

The home-directory string above is explanatory only; application code does not hardcode a user home path.

A successful import does not depend on the original source remaining in place. Bardo validates the audio, copies it to a temporary file inside the managed recording directory, atomically renames that copy to its final managed filename, then publishes the manifest. The original file is never moved or deleted.

## Manifest schemas

### Schema 1

Phase 1 manifests remain readable and reconstruct with no managed audio assets.

### Schema 2

All new writes use schema 2. It retains the Phase 1 recording metadata and adds persisted audio asset identity plus:

```text
originalFileName
fileExtension
duration
codec
sampleRate
channelCount
```

The managed absolute path is not persisted in Domain. `RecordingStore` derives it from recording UUID, audio asset UUID, and the persisted extension.

Unsupported future schema versions are detected and preserved rather than silently migrated or deleted.

## Recovery semantics

Bardo keeps the policy:

`preserve → detect → inform → continue loading healthy data`

In addition to Phase 1 manifest recovery, Phase 2 detects missing managed audio and interrupted `.audio-*.tmp` import residue. A corrupt manifest does not cause Bardo to erase an existing audio file. A missing or corrupt managed audio resource produces a controlled playback/recovery state rather than crashing the Library.

## Test audio

Tests generate tiny deterministic WAV fixtures programmatically with AVFoundation. No network resource and no large multimedia fixture is required or committed.

## Repository structure

```text
Bardo/
├── App/
├── Audio/
│   ├── AudioImportService.swift
│   └── AudioPlaybackController.swift
├── Domain/
│   ├── AudioAsset.swift
│   ├── AudioSource.swift
│   ├── ProcessingState.swift
│   ├── Recording.swift
│   └── Transcript.swift
├── Features/
│   └── Library/
└── Persistence/

BardoTests/
├── AudioImportTests.swift
├── AudioPlaybackControllerTests.swift
├── AudioRecoveryTests.swift
├── AudioTestFixture.swift
├── Phase2IntegrationTests.swift
└── ... Foundation / Phase 1 regression tests
```

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI framework: SwiftUI
- Audio frameworks: native AVFoundation / AVFAudio
- Project generator: XcodeGen
- Runtime third-party dependencies: none

## Explicitly out of scope

Phase 2 does not implement microphone capture, ScreenCaptureKit, WhisperKit, SpeakerKit, transcription, diarization, VAD, AI processing, export, transcript editing, or waveform editing.

See `PROJECT_STATE.md` for the exact certification state, tests, recovery invariants, known debt, and the next permitted phase.
