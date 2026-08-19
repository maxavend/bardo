# Bardo Project State

## Current phase

3 — Microphone Recording

**Status:** PHASE_READY

Phases 0–2 remain integrated and certified. Phase 3 is fully implemented on `feat/phase-3-microphone-recording`; code-bearing head `05469b069f9b9d4345a47aebaa5b923f33213808` passed the complete macOS build/test gate before this documentation-only certification commit.

## Integrated baseline

- Phase 0 — Foundation: certified and merged.
- Phase 1 — Library & Persistence: certified and merged via PR #2.
- Phase 2 — Audio Import: certified and merged via PR #3.
- Phase 2 merge commit on `main`: `fea7ef6a291bd8d7acb4b25afd5705541672e96e`.
- Phase 3 branch: `feat/phase-3-microphone-recording`, created exactly from that merge commit.
- Phase 3 PR: #4 — `Phase 3 — Microphone Recording`.
- Platform invariants: macOS 15+, Swift 6, SwiftUI, XcodeGen, no runtime third-party dependencies.

## Mission 3.1 — Microphone Permissions

**Status:** COMPLETE.

- Uses native AVFoundation microphone authorization state/request APIs.
- Explicit application states: `notDetermined`, `authorized`, `denied`, `restricted`, and unexpected error.
- Permission is requested only after an explicit Record action; an empty launch does not request it.
- Denied/restricted permission never starts the capture backend and produces controlled UI state.
- Denied UI offers a best-effort route to the macOS microphone privacy settings.
- `NSMicrophoneUsageDescription` is owned by `project.yml`; CI verifies the exact key/value in the generated `Bardo.app/Contents/Info.plist`.
- A pending permission prompt does not hold application termination open indefinitely.

## Mission 3.2 — Recorder

**Status:** COMPLETE.

Production capture is implemented by `AVAudioRecorderCaptureBackend` behind the small Phase-3-specific `AudioCapturing` contract.

Production format:

```text
container: M4A
codec: AAC
sample rate: 48,000 Hz
channels: 1 (mono)
bit rate: 96 kbps
encoder quality: high
```

Rationale: direct native recording to a compact, broadly playable conversation format without conversion or future-Phase assumptions.

`AVAudioRecorder` writes directly to the staging file while capture is active. Bardo does not retain the complete recording in RAM. Elapsed time is sampled from the recorder backend's `currentTime`; the UI timer only samples that clock every 250 ms and is cancelled when no longer needed.

Pause/resume is intentionally not implemented in Phase 3. Start/active/stop/finalize/error are the certified lifecycle.

The current microphone display name is shown as informational UI while recording. Durable recording origin uses the already-persisted `Recording.sources = [.microphone]`; no ephemeral hardware identifier/path was promoted into Domain.

## Mission 3.3 — Recording Safety

**Status:** COMPLETE.

Active capture uses Bardo-owned temporary storage separate from final Library records:

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

A staging capture is never a finalized Library Recording.

Successful stop order:

```text
stop/close AVAudioRecorder
→ validate/read technical metadata with AVFoundation
→ construct AudioAsset + Recording(source: microphone)
→ reuse certified RecordingStore.importRecording transaction
→ managed audio copied/finalized before manifest publication
→ remove staging only after publication succeeds
→ reload Library
```

If start fails, the prepared staging directory is removed and no Recording is published. If recording is unexpectedly interrupted or final publication fails, the staging bytes are preserved and detected on recovery; no false-valid Recording is created.

Normal application termination while recording uses the AppKit terminate-later/reply lifecycle to attempt safe stop/finalization before exit. Crash/SIGKILL recovery is not faked: leftover staging bytes are preserved and reported on next launch, but Bardo does not promise recovery of a container the OS/framework cannot decode.

Concurrency invariants:

- orchestration rejects a second start while the same controller is busy;
- a process-wide capture lease rejects simultaneous capture from separate controllers;
- the staging actor independently rejects a second active prepared capture;
- the app uses a single main SwiftUI `Window`, so another window cannot visually claim an idle recorder while capture is active elsewhere;
- repeated `stop` after completion is controlled/idempotent from the application perspective.

## Mission 3.4 — Recording UI

**Status:** COMPLETE for automated validation; interactive visual smoke remains PARTIAL.

The native macOS UI exposes:

- idle Record action in the toolbar;
- permission-request state;
- preparing state;
- unmistakable active recording bar;
- elapsed duration with monospaced digits;
- current input display name when available;
- Stop action;
- finalizing state;
- controlled error/permission-denied alert;
- preserved incomplete-capture recovery notice.

After successful stop, the existing Library is reloaded, the new Recording is selected, and the existing Phase 2 playback path is prepared. No parallel microphone-only Library exists.

## Schema

Current write schema remains **2**.

Phase 3 does not require a manifest change: `AudioSource.microphone` already existed in the persisted Phase 2 contract. V1/V2 compatibility and all existing recovery behavior remain unchanged. No absolute capture paths or transient microphone identifiers are persisted in Domain.

## Integrated gate

CI uses a hardware-independent `AudioCapturing` backend that writes a real deterministic WAV with AVFoundation while capture is active; it is not an in-memory audio mock.

Automated evidence demonstrates:

```text
authorized intent
→ prepare Bardo staging
→ real audio bytes exist on disk before stop
→ stop/finalize
→ AVFoundation metadata
→ AudioAsset + Recording(.microphone)
→ RecordingStore managed publication
→ Library reload
→ AVAudioPlayer load/play/pause
→ fresh RecordingStore + fresh LibraryViewModel
→ Recording reconstructs from disk
→ playback remains available ✅
```

Additional certified scenarios:

```text
second simultaneous start → rejected ✅
backend start failure → no false Recording + healthy Library ✅
unexpected interruption → staging preserved + no false Recording ✅
normal app termination during recording → finalized Recording ✅
pending permission prompt + app termination → no termination deadlock ✅
```

A simulated `currentTime = 3600.75` verifies long-duration state without sleeping CI for an hour. Production architecture remains direct-to-disk and does not scale RAM use with captured audio length by design.

## Tests and CI evidence

Final code-bearing GitHub Actions run `32300431536` validated commit `05469b069f9b9d4345a47aebaa5b923f33213808` on:

- macOS 15.7.7 Apple Silicon;
- Xcode 16.4 (16F6);
- Apple Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0.

Observed results:

- XcodeGen install/generation: passed;
- Debug build: **BUILD SUCCEEDED**;
- app bundle/executable verification: passed;
- generated `NSMicrophoneUsageDescription`: passed;
- XCTest: **TEST SUCCEEDED**;
- **47 tests executed, 0 failures**.

The 47-test suite includes all inherited Foundation/Phase 1/Phase 2 regressions plus permission lifecycle, production recorder configuration, staging/recovery, concurrency, direct-to-disk evidence, long-duration clock behavior, interruption/error paths, termination behavior, and the full Phase 3 restart/playback gate.

No material Swift compiler warning attributable to Phase 3 appears in the inspected CI log. Non-material runner/framework diagnostics remain unrelated Homebrew tap-trust noise, AppIntents metadata skips because Bardo does not use AppIntents, deliberately corrupt Phase 2 audio diagnostics, and virtual-runner playback-device messages.

This documentation-only certification head must pass the same PR workflow before PR #4 is marked ready for external review.

## Reviewer findings and repairs

The global reviewer loop found and resolved material issues before certification:

1. Rejected an unnecessary proposed schema 3/device-label persistence design. Phase 3 now reuses schema 2 and existing `AudioSource.microphone` instead of duplicating persistence contracts.
2. Found that termination could wait indefinitely while a microphone permission prompt was pending. Termination is now delayed only for actual recording/finalization; a dedicated suspended-permission test covers the regression.
3. Found that `WindowGroup` could allow another window to appear idle while a different window owned the microphone. The main scene is now a single `Window`; the process-wide capture lease remains defense in depth.

After each material repair the full CI gate was rerun. A third reviewer pass found no further material issue. The final code diff is ahead of `main` only, introduces no runtime dependency, leaves persistence/schema code untouched, and contains no Phase 4 implementation.

## Recovery and safety invariants

- An incomplete microphone capture is staging data, never a finalized Recording.
- Final manifest publication occurs only after a closed/valid audio resource can be inspected and adopted by `RecordingStore`.
- Recording finalization reuses the Phase 2 managed-audio transaction instead of creating a second persistence system.
- Interrupted/finalization-failed bytes are preserved and reported, not silently deleted.
- One broken/incomplete capture does not prevent Library from loading healthy recordings.
- Only one microphone capture can own the process at a time.
- Progress polling exists only while actively recording.
- The complete conversation is never accumulated in Bardo memory by design.
- Existing import, metadata, playback, schema compatibility, and recovery invariants remain green.

## Known minor debt / evidence pending

- **PARTIAL — interactive microphone smoke test pending:** CI cannot grant the real macOS TCC microphone prompt, speak into physical hardware, listen to the production M4A capture, or visually inspect the running recording UX. No physical microphone success is claimed.
- The production `AVAudioRecorder` implementation/configuration compiles on Xcode 16.4; lifecycle/media integration in CI uses a real AVFoundation-generated WAV backend because the runner does not provide an interactive microphone permission/device test.
- The System Settings microphone deep link is best-effort; denial handling remains correct even if macOS changes that navigation route.
- Pause/resume is intentionally absent.
- Advanced device-route monitoring/reselection is not implemented; recorder delegate failures are surfaced and staged bytes preserved.
- No explicit disk-full hardware simulation exists; start/write/finalization failures use the same controlled failure/preservation path.
- No waveform, system audio, source mixing, transcription, diarization, export, or AI processing exists.

## Explicitly out of scope

Phase 3 contains no ScreenCaptureKit, system-audio capture, microphone+system mixing, WhisperKit, SpeakerKit, transcription, diarization, VAD, waveform, export, or Phase 4 implementation.

## Next phase

After PR #4 is reviewed and merged, the next permitted phase is:

- **4 — System Audio**

Do not implement Phase 4 before Phase 3 integration.
