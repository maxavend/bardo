# Bardo

Bardo is a privacy-first, on-device macOS app for turning conversations into durable recording metadata and, in later phases, speaker-aware transcripts. The repository is currently implementing **Phase 1 — Library & Persistence**: recordings can be stored on disk, reconstructed after a process restart, represented in a native macOS Library, and isolated from neighboring corrupt entries.

Phase 1 intentionally contains **zero AI** and no real audio import or capture.

## Development requirements

- macOS 15 or later
- Xcode 16 or later with the Swift 6 toolchain
- XcodeGen 2.46.0 or later

CI validates the project on macOS 15 with Xcode 16.4.

Install XcodeGen with Homebrew:

```sh
brew install xcodegen
```

## Generate the Xcode project

`project.yml` is the source of truth for Xcode project configuration. The generated `Bardo.xcodeproj` is intentionally not versioned.

```sh
xcodegen generate
```

To regenerate from scratch:

```sh
rm -rf Bardo.xcodeproj
xcodegen generate
```

## Build

```sh
xcodebuild \
  -project Bardo.xcodeproj \
  -scheme Bardo \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The application bundle is produced at:

```text
.derived-data/Build/Products/Debug/Bardo.app
```

For normal development, open `Bardo.xcodeproj` in Xcode and run the `Bardo` scheme on My Mac.

## Tests

```sh
xcodebuild \
  -project Bardo.xcodeproj \
  -scheme Bardo \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The Phase 1 suite covers Foundation regressions, recording persistence, restart reconstruction, Library state, corrupt/incomplete manifests, interrupted-write residue, and the integrated healthy/corrupt/healthy recovery scenario.

## Current functionality

Bardo currently provides:

- a native SwiftUI macOS application;
- a `NavigationSplitView` recording Library;
- real on-disk `RecordingStore` persistence;
- stable UUID recording identity;
- explicit schema-versioned manifests;
- reconstruction from disk using fresh store/view-model instances;
- controlled recovery reporting that preserves defective entries while continuing to load healthy recordings.

There are no production seed recordings. Until a later phase adds real input, an empty Library is the expected fresh-install state; persisted examples are created only in tests.

## Persistent Library

The live store uses the user's Application Support directory:

```text
~/Library/Application Support/Bardo/Library/
└── <recording-uuid>/
    └── manifest.json
```

The exact Application Support root is resolved through `FileManager`; application code does not hardcode a user home path.

### Manifest schema 1

Each `manifest.json` currently persists:

```text
schemaVersion: 1
id: UUID
title: String
createdAtEpochSeconds: Double
duration: Double?
sources: [AudioSource]
processingState: ProcessingState
```

The persistence manifest is deliberately separate from `Recording`'s direct `Codable` representation. Future domain changes therefore cannot silently redefine the on-disk schema.

There is no migration framework yet. The loader reads `schemaVersion`, understands V1, and reports unsupported versions without modifying or deleting them.

### Write and recovery semantics

A manifest is fully encoded before filesystem replacement begins. The store writes a temporary manifest in the same recording directory and commits it with POSIX `rename(2)`, giving an atomic namespace replacement on the same filesystem. Bardo does not claim `fsync`/power-loss durability beyond that guarantee.

Incomplete or suspicious entries are preserved rather than deleted automatically. Corrupt manifests, missing manifests, unsupported schemas, UUID mismatches, unexpected entries, and `.manifest-*.tmp` residue become recovery issues while healthy recordings continue loading.

## Repository structure

```text
.github/
└── workflows/
    └── ci.yml
Bardo/
├── App/
│   ├── BardoApp.swift
│   └── RootView.swift
├── Domain/
│   ├── AudioSource.swift
│   ├── ProcessingState.swift
│   ├── Recording.swift
│   └── Transcript.swift
├── Features/
│   └── Library/
│       ├── LibraryView.swift
│       └── LibraryViewModel.swift
└── Persistence/
    ├── RecordingManifest.swift
    ├── RecordingStore.swift
    └── RecordingStoreIssue.swift
BardoTests/
├── BootstrapTests.swift
├── DomainModelTests.swift
├── LibraryViewModelTests.swift
├── Phase1IntegrationTests.swift
├── RecordingStoreRecoveryTests.swift
└── RecordingStoreTests.swift
project.yml
README.md
PROJECT_STATE.md
```

Only directories containing real implementation are created.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI framework: SwiftUI
- Project generator: XcodeGen
- Generated project: `Bardo.xcodeproj` (not committed)
- Runtime third-party dependencies: none

## Explicitly out of scope

Phase 1 does not implement audio import, microphone capture, ScreenCaptureKit, WhisperKit, SpeakerKit, transcription, diarization, AI processing, or speculative APIs for those future capabilities.

See `PROJECT_STATE.md` for the exact validation state, architectural decisions, recovery invariants, and the next permitted phase.
