# Bardo

Bardo is a privacy-first native macOS app for managing conversations locally. Phases 0–2 are integrated, and **Phase 3 — Microphone Recording** is implemented on its phase branch: Bardo can import existing audio or record a new local microphone conversation, keep the audio under Bardo-managed storage, reconstruct it after restart, and play it through the same Library.

Bardo still contains **zero AI**. There is no transcription, diarization, system-audio capture, or cloud processing.

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

## Current functionality

Bardo provides:

- native single-window SwiftUI macOS application;
- `NavigationSplitView` Library with persistent per-recording recovery isolation;
- native file picker and drag & drop import for `.m4a`, `.mp3`, `.wav`, `.flac`, `.aac`, `.aiff` when AVFoundation can actually read the content;
- Bardo-managed copies of successfully imported audio;
- native microphone permission lifecycle initiated only by explicit recording intent;
- XcodeGen-managed `NSMicrophoneUsageDescription`, Hardened Runtime, and macOS Audio Input entitlement configuration;
- native `AVAudioRecorder` microphone capture directly to disk;
- production microphone format: AAC/M4A, mono, 48 kHz, 96 kbps;
- visible recording duration and input-device name while capture is active;
- safe staging/finalization before a microphone capture becomes a normal Library Recording;
- persisted duration, codec label, sample rate, and channel count through the existing `AudioAsset` model;
- native play, pause, seek, current-position, and total-duration controls;
- schema-versioned persistence with current write schema **2**.

## Microphone capture lifecycle

Microphone recordings do not create a parallel persistence system. Active audio first lives in Bardo-owned staging storage:

```text
Application Support/Bardo/
├── Library/
│   └── <recording-uuid>/
│       ├── manifest.json
│       └── audio/<audio-asset-uuid>.<ext>
└── .MicrophoneCaptureStaging/
    └── <recording-uuid>/
        └── <audio-asset-uuid>.m4a
```

Successful finalization is:

```text
record directly to staging
→ stop/close recorder
→ AVFoundation validation + metadata
→ Recording + AudioAsset(source: microphone)
→ existing RecordingStore managed-audio transaction
→ manifest publication
→ remove staging
→ Library + existing playback
```

If capture is interrupted or final publication fails, Bardo does not publish a false Recording. Temporary bytes are preserved for recovery and healthy Library recordings continue loading.

Only one microphone capture can own Bardo at a time. The application uses a single main window, the recording controller keeps a process-wide capture lease, and the staging actor independently rejects a second active prepared capture.

## Permissions and macOS configuration

`NSMicrophoneUsageDescription` is generated from `project.yml`, and CI verifies that it exists in the built application bundle. Bardo requests microphone access only after Record is chosen. Denied or restricted access never starts the recorder.

The macOS target also declares:

```text
CODE_SIGN_ENTITLEMENTS = Bardo/Bardo.entitlements
ENABLE_HARDENED_RUNTIME = YES
com.apple.security.device.audio-input = true
```

CI verifies those generated settings and entitlement source. CI intentionally builds with code signing disabled, so the final embedded entitlement in a normally signed app remains part of the physical/signed smoke test rather than being falsely claimed as automated evidence.

When Bardo is closed during a real active recording, the AppKit termination lifecycle attempts to stop and safely finalize the capture before exit. A pending permission prompt is not treated as recorded data and does not hold application termination open indefinitely.

## Managed audio and schemas

Imported audio and microphone recordings converge on the same `Recording + AudioAsset + RecordingStore + Library + Playback` model.

Schema 1 remains readable for Phase 1 recordings. Schema 2 remains the current write format and persists audio asset identity/metadata. Phase 3 did not bump the schema because `AudioSource.microphone` was already part of the persisted contract.

Absolute managed paths and transient microphone identifiers are not persisted in Domain.

## Recovery semantics

Bardo keeps the policy:

`preserve → detect → inform → continue loading healthy data`

This covers corrupt/incomplete manifests, missing/corrupt managed audio, import temporary residue, and interrupted microphone staging residue. An incomplete microphone file is never presented as a finalized recording merely because bytes exist.

## Tests

The final Phase 3 code/configuration gate contains **47 XCTest cases with 0 failures**, including all Foundation/Phase 1/Phase 2 regressions.

Hardware-independent microphone integration uses a deterministic AVFoundation backend that writes a real WAV file incrementally to disk. Tests demonstrate bytes written before stop, metadata extraction, publication through the real `RecordingStore`, Library reconstruction, playback through `AVAudioPlayer`, restart persistence, concurrent-start rejection, interruption recovery, and normal termination finalization.

The production `AVAudioRecorder` backend and M4A/AAC configuration compile under Xcode 16.4. A real physical-microphone/TCC/listening/visual smoke test — including a normally signed build with the entitlement embedded — remains intentionally documented as pending because GitHub Actions cannot perform that interactive validation.

## Project configuration

- Platform: macOS 15+
- Language mode: Swift 6
- UI framework: SwiftUI / AppKit lifecycle bridge
- Audio frameworks: native AVFoundation / AVFAudio
- Project generator: XcodeGen
- Runtime third-party dependencies: none

## Explicitly out of scope

Phase 3 does not implement ScreenCaptureKit, system audio, microphone+system mixing, WhisperKit, SpeakerKit, transcription, diarization, VAD, waveform, export, transcript editing, or AI processing.

See `PROJECT_STATE.md` for exact phase certification evidence, CI, reviewer repairs, recovery invariants, known debt, and the next permitted phase.
