# Bardo

Bardo is a privacy-first, on-device macOS app for turning conversations into speaker-aware transcripts. The repository is currently at **Phase 0 — Foundation**: it contains the native app shell, reproducible XcodeGen configuration, automated build/test validation, and the minimum serializable domain model. Audio capture, persistence, import, transcription, diarization, and other product features are intentionally not implemented yet.

## Development requirements

- macOS 15 or later
- Xcode 16 or later with the Swift 6 toolchain
- XcodeGen 2.46.0 or later

CI currently validates the project on macOS 15 with Xcode 16.4.

Install XcodeGen with Homebrew:

```sh
brew install xcodegen
```

## Generate the Xcode project

`project.yml` is the source of truth for Xcode project configuration. The generated `Bardo.xcodeproj` is intentionally not versioned.

From the repository root:

```sh
xcodegen generate
```

To regenerate from scratch:

```sh
rm -rf Bardo.xcodeproj
xcodegen generate
```

## Build

Generate the project first, then run:

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

Run the Foundation test suite with:

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

The current suite verifies that the bootstrap view can be constructed and that the Foundation domain models preserve their values through `Codable` round trips.

## Continuous integration

`.github/workflows/ci.yml` runs for pull requests and pushes to `main`. The workflow:

1. selects Xcode 16.4 on a macOS 15 runner;
2. installs XcodeGen;
3. generates `Bardo.xcodeproj` from `project.yml`;
4. builds Bardo for macOS;
5. verifies that the `.app` bundle and executable were produced;
6. runs the unit test suite.

## Repository structure

```text
.github/
└── workflows/
    └── ci.yml
Bardo/
├── App/
│   ├── BardoApp.swift
│   └── RootView.swift
└── Domain/
    ├── AudioSource.swift
    ├── ProcessingState.swift
    ├── Recording.swift
    └── Transcript.swift
BardoTests/
├── BootstrapTests.swift
└── DomainModelTests.swift
project.yml
README.md
PROJECT_STATE.md
```

Only directories containing real code or assets are created. Feature, infrastructure/service, persistence, shared, and resource areas will be introduced when their owning phase requires them rather than as empty placeholders.

## Foundation domain contracts

Phase 0 defines only data contracts that are already meaningful to Bardo:

- `AudioSource`
- `ProcessingState`
- `Recording`
- `Speaker`
- `TranscriptSegment`
- `Transcript`

These values are `Codable`, `Equatable`, and `Sendable` where appropriate so later persistence and asynchronous work can build on explicit, testable semantics.

Service protocols such as capture, storage, transcription, or diarization are intentionally deferred until their first real consumer exists. Defining their inputs and outputs before Bardo has corresponding audio/persistence concepts would create speculative APIs.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI framework: SwiftUI
- Project generator: XcodeGen
- Generated project: `Bardo.xcodeproj` (not committed)
- Runtime third-party dependencies: none in Phase 0

See `PROJECT_STATE.md` for certified capabilities, evidence, invariants, and the next permitted phase.
