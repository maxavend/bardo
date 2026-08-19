# Bardo

Bardo is a privacy-first native macOS app for capturing and managing conversations locally. Phases 0–3 are integrated, and **Phase 4 — System Audio** is implemented on its phase branch: Bardo can import audio, record microphone-only conversations, capture audio from macOS content selected with the native system picker, or capture system audio and microphone as independent originals with a derived playback mix.

Bardo still contains **zero AI**. There is no transcription, diarization, WhisperKit, SpeakerKit, cloud processing, or Phase 5 implementation.

## Development requirements

- macOS 15 or later
- Xcode 16 or later with the Swift 6 toolchain
- XcodeGen 2.46.0 or later

CI validates the project on macOS 15 with Xcode 16.4.

```sh
brew install xcodegen
xcodegen generate
```

`project.yml` remains the source of truth; `Bardo.xcodeproj` and the generated `Bardo/Info.plist` are not committed.

## Current functionality

Bardo provides:

- native single-window SwiftUI macOS application;
- persistent Library with per-recording recovery isolation;
- native audio import into Bardo-managed storage;
- Phase 3 microphone-only capture through `AVAudioRecorder`;
- native `SCContentSharingPicker` selection for display, application, or window;
- ScreenCaptureKit system-audio capture without persisting video;
- system-only recording and system + microphone dual-source recording;
- same-`SCStream` `.audio` and `.microphone` outputs for dual mode;
- direct-to-disk M4A/AAC writers rather than full-session audio buffering;
- Bardo playback exclusion from system capture through `excludesCurrentProcessAudio`;
- source-relative timeline alignment derived from ScreenCaptureKit presentation timestamps;
- independent `systemOriginal` and `microphoneOriginal` assets plus a regenerable `conversationMix` derived asset;
- native AVFoundation mix generation with deterministic headroom;
- playback preference for the conversation mix with fallback to preserved originals if the mix is missing or unreadable;
- safe staging, partial-source preservation, stream-invalidation handling, and normal-termination finalization;
- a process-wide recording lease shared by microphone-only and system capture;
- source reselection during system capture through the native picker;
- schema-versioned persistence with current write schema **3**, while V1 and V2 remain readable.

## System audio architecture

System-only:

```text
SCContentSharingPicker
→ SCContentFilter
→ SCStream (.audio)
→ incremental M4A/AAC writer
→ systemOriginal AudioAsset
→ RecordingStore
→ Library + Playback
```

Dual source:

```text
one SCStream
├── .audio       → systemOriginal.m4a
└── .microphone  → microphoneOriginal.m4a
                         │
source PTS offsets ──────┘
          ↓
AVFoundation composition/export
          ↓
conversationMix.m4a (derived)
```

The original source files are primary evidence and are never replaced by the mix. The mix persists its source asset IDs and can be reproduced from the originals and their normalized timeline offsets.

## Formats

Production microphone-only source:

```text
M4A / AAC / 48 kHz / mono / 96 kbps
```

Production ScreenCaptureKit system source:

```text
M4A / AAC / 48 kHz / stereo / 128 kbps
```

Dual ScreenCaptureKit microphone source:

```text
M4A / AAC / 48 kHz / mono / 96 kbps
```

The derived conversation mix is exported as M4A with AVFoundation. Each source receives 0.5 linear gain in the mix to provide deterministic summing headroom; this is not perceptual loudness normalization.

## Persistence

Schema 3 adds durable semantics to `AudioAsset`:

- role (`importedOriginal`, `microphoneOriginal`, `systemOriginal`, `conversationMix`);
- recording-relative `timelineOffset`;
- `derivedFromAssetIDs` for derived assets.

V1 and V2 manifests remain readable without destructive migration. ScreenCaptureKit objects, picker/content IDs, absolute host timestamps, microphone device IDs, temporary paths, and managed absolute paths are not persisted in Domain.

All finalized files still use the same `Recording + AudioAsset + RecordingStore + Library + Playback` infrastructure. There is no parallel system-audio library.

## Permissions and privacy

The XcodeGen-generated application configuration includes:

- `NSMicrophoneUsageDescription`;
- `NSScreenCaptureUsageDescription`;
- Hardened Runtime configuration;
- the Phase 3 macOS Audio Input entitlement.

CI verifies the generated application bundle privacy strings and build configuration. System content is selected through the native macOS sharing picker rather than a privacy-bypassing custom selector.

CI intentionally builds unsigned, so real TCC interaction and production-signed entitlement behavior remain interactive smoke tests.

## Recovery semantics

Bardo keeps the policy:

`preserve → detect → inform → continue`

A staging file is not a finalized Recording. If one dual source fails, a healthy source can still be safely published while incomplete staging evidence is preserved. A missing or corrupt derived mix does not damage the originals and playback can fall back to a source asset.

## Tests

The Phase 4 code/configuration gate currently contains **66 XCTest cases with 0 failures**, including all Phase 0–3 regressions.

Automated coverage includes system-only and dual-source lifecycle, picker cancellation/failure/reselection, ScreenCaptureKit configuration, real M4A fixture writing, shared-stream PTS alignment, schema V1/V2/V3 compatibility, multi-asset publication, AVFoundation mix generation and playback, missing/corrupt mix fallback, source-specific failures, stream invalidation, staging recovery, shared recording lease, normal application termination, long-duration clock behavior, Library reconstruction, and restart persistence.

Real `SCContentSharingPicker` interaction, real third-party application audio, physical microphone dual capture, human listening, and normally signed/TCC behavior remain intentionally documented as `PARTIAL` because GitHub Actions cannot provide that interactive evidence.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI: SwiftUI / AppKit lifecycle bridge
- Audio/capture frameworks: AVFoundation / AVFAudio / ScreenCaptureKit
- Project generator: XcodeGen
- Runtime third-party dependencies: none

## Explicitly out of scope

Phase 4 does not implement WhisperKit, SpeakerKit, transcription, diarization, VAD, summaries, transcript editing, waveform, or other Phase 5+ functionality.

See `PROJECT_STATE.md` for exact certification evidence, CI, reviewer repairs, recovery invariants, known debt, and the next permitted phase.
