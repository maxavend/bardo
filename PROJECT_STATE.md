# Bardo Project State

## Current phase

4 — System Audio

**Status:** PHASE_READY

Phases 0–3 are integrated and certified. Phase 4 is fully implemented on `feat/phase-4-system-audio` and contains no Phase 5 functionality.

An interactive smoke test on a real Apple Silicon Mac running macOS 27 exposed a Swift 6 executor-isolation crash when ScreenCaptureKit invoked its `startCapture` completion on `com.screenCaptureKit.streamQueue`. The crash report showed `_swift_task_checkIsolatedSwift` / `_dispatch_assert_queue_fail` inside the completion thunk. The production fix is commit `287f01424db4d24b0a2b8e63335e8105349eb325`: ScreenCaptureKit start/update/stop completions are now created by a nonisolated `@Sendable` bridge while `SCStream` itself remains MainActor-confined. Commit `305b26af30851106b8c4734dc9782c9809a0bfe8` adds a regression that invokes that bridge from a framework-style background dispatch queue.

GitHub Actions run `32325966054` (CI #63) validated the repaired code head with XcodeGen generation, capture/privacy configuration, Debug build, application bundle verification, and **71 XCTest cases with 0 failures**.

## Integrated baseline

- Phase 0 — Foundation: certified and merged.
- Phase 1 — Library & Persistence: certified and merged via PR #2.
- Phase 2 — Audio Import: certified and merged via PR #3.
- Phase 3 — Microphone Recording: certified and merged via PR #4.
- Phase 3 merge commit on `main`: `76146d1459606bff1b0a177a2a4d96c1e4264df9`.
- Phase 4 branch: `feat/phase-4-system-audio`, created exactly from that merge commit.
- Phase 4 PR: #5 — `Phase 4 — System Audio`.
- Platform invariants: macOS 15+, Swift 6, SwiftUI, XcodeGen, no runtime third-party dependencies.

## Mission 4.1 — ScreenCaptureKit + native picker

**Status:** COMPLETE for automated validation; corrected interactive System Audio smoke remains PARTIAL.

- Uses `SCContentSharingPicker.shared`; no custom content browser or privacy bypass.
- Picker supports display, application, and window selection.
- Bardo excludes its own bundle from picker choices where the system API permits it.
- Initial cancellation or picker error creates no Recording and releases the process-wide capture lease.
- `Change Source…` reopens the native picker during an active recording and applies the returned `SCContentFilter` to the existing stream.
- Cancelling reselection leaves the current recording active.
- No `.screen` output is registered and no video frame is persisted.
- `NSScreenCaptureUsageDescription` is generated from XcodeGen-owned configuration and CI verifies the built bundle.
- ScreenCaptureKit completion handlers are explicitly nonisolated `@Sendable` closures because the framework calls them on framework-owned queues. Application state mutations still hop to MainActor.

## Mission 4.2 — System Audio Capture

**Status:** COMPLETE.

Production system audio uses ScreenCaptureKit behind the Phase-4-specific `SystemAudioCapturing` boundary.

`SCStreamConfiguration` uses:

```text
capturesAudio: true
sampleRate: 48,000 Hz
channelCount: 2
excludesCurrentProcessAudio: true
captureMicrophone: false for system-only
minimal visual stream configuration; no screen output registered
```

System samples arrive through `.audio` and are written incrementally by `CMSampleBufferAudioWriter` using `AVAssetWriter`.

Production system source format:

```text
container: M4A
codec: AAC
sample rate: 48,000 Hz
channels: 2 (stereo)
bit rate: 128 kbps
```

Bardo does not retain the complete session in memory. Append/backpressure failures are surfaced as controlled capture failures. `excludesCurrentProcessAudio = true` prevents Bardo playback from intentionally feeding back into the captured system track.

## Mission 4.3 — System + Microphone

**Status:** COMPLETE.

Dual capture uses a single `SCStream`:

```text
same SCStream
├── .audio       → system original
└── .microphone  → microphone original
```

Dual-mode configuration:

- `captureMicrophone = true`;
- `microphoneCaptureDeviceID` uses the current default audio capture device when available;
- system and microphone outputs are written to separate M4A files;
- microphone source format is AAC/M4A, 48 kHz, mono, 96 kbps;
- Phase 3 microphone-only recording remains on its certified `AVAudioRecorder` implementation.

Synchronization contract:

- first/last `CMSampleBuffer` presentation timestamps are tracked independently for each source;
- both source outputs come from the same `SCStream` clock domain;
- the earliest first PTS defines recording-relative time zero;
- every original persists a normalized `timelineOffset` relative to that origin;
- absolute host timestamps and ephemeral ScreenCaptureKit identifiers are not persisted.

A failure of one requested source does not silently destroy a healthy source. A valid remaining original can be published while incomplete staging is preserved and the degradation is surfaced.

## Mission 4.4 — Derived conversation mix

**Status:** COMPLETE.

When both originals are valid Bardo creates a derived playback representation:

```text
system original
+
microphone original
↓
AVMutableComposition at persisted timeline offsets
↓
0.5 linear gain per source
↓
AVAssetExportSession.export(to:as:)
↓
conversation mix M4A
```

The fixed 0.5 gain is deterministic summing headroom, not perceptual loudness normalization.

The derived mix:

- never replaces or mutates source originals;
- persists `derivedFromAssetIDs` identifying its inputs;
- is reproducible from the originals and their persisted offsets;
- is preferred for Library playback;
- falls back to a healthy original when missing or unreadable;
- cannot make source originals invalid merely because it is missing/corrupt.

Real AVFoundation fixtures verify mix generation and loading through the existing playback controller.

## Durable asset model and schema

Current write schema is **3**.

Phase 4 introduced the first durable need to distinguish audio-file semantics. `AudioAsset` now persists:

- `role`: `importedOriginal`, `microphoneOriginal`, `systemOriginal`, or `conversationMix`;
- recording-relative `timelineOffset`;
- `derivedFromAssetIDs` for derived assets.

Compatibility remains non-destructive:

- V1 remains readable;
- V2 remains readable;
- V2 microphone-only assets infer `microphoneOriginal`;
- V2 system-only assets infer `systemOriginal` when encountered;
- other legacy V2 assets infer `importedOriginal`;
- V3 is the current write format.

No `SCContentFilter`, content identifier, absolute host timestamp, transient microphone device ID, staging path, or managed absolute path is persisted in Domain.

## Publication and recovery

Active system capture uses Bardo-owned staging separate from finalized Library state:

```text
Application Support/Bardo/
├── Library/<recording-uuid>/
│   ├── manifest.json
│   └── audio/<audio-asset-uuid>.<ext>
└── .SystemAudioCaptureStaging/<recording-uuid>/
    ├── system original
    ├── microphone original   (dual mode)
    └── conversation mix      (derived when generated)
```

Successful publication order:

```text
stop SCStream
→ drain queued sample callbacks
→ finalize writers
→ validate readable originals + metadata
→ normalize timeline offsets
→ create derived mix when both originals are valid
→ RecordingStore.importRecording(all valid assets)
→ finalize managed audio before manifest publication
→ remove staging only when requested originals are healthy
→ reload Library
```

Recovery philosophy remains:

`preserve → detect → inform → continue`

Certified scenarios include:

- system + microphone both valid;
- microphone failure with system preserved/published;
- system failure with microphone preserved/published;
- no valid source → no false Recording;
- missing mix → originals intact + playback fallback;
- corrupt mix → originals intact + playback fallback;
- mix generation failure → originals published intact;
- residual system-capture staging detected after restart;
- stream stopped by macOS → available finalized source preserved/published with warning;
- picker cancelled/failed → no Recording;
- normal app termination during active system capture → safe finalization attempted.

## Concurrency and lifecycle invariants

- Phase 3 microphone-only and Phase 4 system capture share one process-wide `RecordingCaptureLease`.
- Picker selection reserves that lease before system capture begins.
- A concurrent Phase 3 microphone start while system capture owns the lease is rejected.
- System staging independently rejects a second prepared system capture.
- The app remains a single SwiftUI `Window`.
- Progress polling exists only during active capture and is cancelled during stop/finalization.
- `SCStream` remains MainActor-confined under Swift 6 strict concurrency.
- `SCStreamDelegate` / picker callbacks explicitly hop to MainActor when mutating application state.
- `SCStream.startCapture`, `updateContentFilter`, and `stopCapture` completion handlers are created outside MainActor isolation through `ScreenCaptureKitCompletionBridge`; this is required because ScreenCaptureKit may invoke them on framework-owned dispatch queues.
- A dedicated regression executes the completion bridge on a non-main dispatch queue and verifies clean continuation resumption.
- Normal app termination delays exit only while an actual recording/finalization must safely finish.

## Integrated automated gate

Hardware-independent integration uses deterministic `SystemAudioCapturing` test backends that write real managed audio fixtures rather than retaining a fake full-session byte array. Mix tests use real AVFoundation composition/export and final playback uses the existing `AVAudioPlayer` path.

Automated evidence covers:

```text
selection
→ system + microphone lifecycle
→ independent original assets
→ shared-stream PTS alignment
→ AVFoundation validation + metadata
→ derived conversation mix
→ schema V3 Recording + AudioAssets
→ RecordingStore managed publication
→ Library
→ playback
→ fresh RecordingStore + LibraryViewModel
→ Recording + originals + mix reconstruct ✅
```

Additional gates:

```text
picker cancel/failure → no Recording ✅
Change Source → existing stream updated ✅
one dual source fails → healthy source preserved ✅
stream invalidation → controlled finalization ✅
missing/corrupt mix → originals intact + playback fallback ✅
Phase 3 mic vs Phase 4 system capture → shared lease rejects overlap ✅
normal termination → finalized system Recording ✅
ScreenCaptureKit completion invoked off-main → continuation resumes without executor trap ✅
```

A simulated capture clock of `3600.75` validates long-duration lifecycle without sleeping CI. Production writers remain direct-to-disk, so memory does not scale with full recording length by design.

## Tests and CI evidence

Crash-repair GitHub Actions run `32325966054` (CI #63) validated commit `305b26af30851106b8c4734dc9782c9809a0bfe8` on:

- macOS 15.7.7 Apple Silicon;
- Xcode 16.4 (16F6);
- Apple Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0.

Observed results:

- XcodeGen generation: passed;
- capture build configuration verification: passed;
- microphone Audio Input entitlement source/settings: passed;
- Debug build: **BUILD SUCCEEDED**;
- generated app bundle/executable verification: passed;
- generated `NSMicrophoneUsageDescription`: passed;
- generated `NSScreenCaptureUsageDescription`: passed;
- XCTest: **TEST SUCCEEDED**;
- **71 tests executed, 0 failures**;
- new off-main ScreenCaptureKit completion regression: passed;
- all inherited Phase 0–3 regressions remain green.

CI builds with `CODE_SIGNING_ALLOWED=NO`, so it cannot prove real production signing or interactive TCC behavior. The built configuration and privacy declarations are automated and green.

## Reviewer findings and repairs

The adversarial reviewer and physical smoke testing caused multiple material repairs before certification:

1. Required schema V3 only for the real durable requirements of source/derived roles and alignment; ephemeral ScreenCaptureKit/device identifiers were rejected from Domain.
2. Repaired inherited schema-2 test assumptions after the justified schema V3 bump.
3. Fixed `SCContentSharingPickerObserver` isolation for Swift 6 with nonisolated callbacks hopping explicitly to MainActor.
4. Rejected weakening strict concurrency when `SCStream` async overloads exposed non-Sendable diagnostics; retained MainActor confinement and wrapped framework completion callbacks.
5. Added `microphoneCaptureDeviceID` for dual same-stream microphone capture without persisting that ephemeral ID.
6. Found that a build-setting-style `NSScreenCaptureUsageDescription` did not reach the generated plist; moved it to XcodeGen's explicit generated Info.plist contract and added CI verification.
7. Removed macOS-15-deprecated AVAssetExportSession callback APIs in favor of `export(to:as:)`.
8. Fixed Swift 6 XCTest actor/autoclosure problems rather than weakening compiler settings.
9. Added missing/corrupt derived-mix fallback and normal-termination tests.
10. Found native picker reselection can return a new filter without an associated stream; added explicit `Change Source…` UX and application of that filter to the existing stream.
11. Added focused CI XCTest failure summaries so runtime failures are not hidden by full `xcodebuild` logs.
12. Replaced fragile synthesized `Recording ==` persistence assertions with the persistence-specific contract, extended to verify Phase 4 roles, offsets and derivation.
13. Added adversarial recovery gates for system-source loss, stream invalidation, and initial picker failure/lease release.
14. The documentation-head CI exposed one remaining V3 persistence test still using synthesized `Recording ==`; it was corrected to the explicit persistence contract and the full suite reran green.
15. **Physical macOS 27 smoke test:** microphone-only capture succeeded, but starting System Audio crashed on `com.screenCaptureKit.streamQueue` with `_swift_task_checkIsolatedSwift`. Root cause was a ScreenCaptureKit completion closure inheriting `MainActor`; start/update/stop now use a nonisolated `@Sendable` completion bridge and CI includes an off-main regression.

Final automated reviewer pass found no remaining material issue, full-session audio accumulation, stored video, irreversible mix, ScreenCaptureKit leakage into Domain, Phase 5 implementation, or runtime third-party dependency.

## Known minor debt / evidence pending

- **Physical microphone smoke: PASSED** on the development build used for interactive testing.
- **PARTIAL — corrected system-audio smoke retest pending:** the original physical attempt found the executor-isolation crash described above; the repaired code is green in CI, but the corrected build has not yet been re-run interactively against real system audio on macOS 27.
- **PARTIAL — interactive dual-source smoke test pending:** physical system+microphone capture and human listening/alignment remain to be repeated after the executor repair.
- **PARTIAL — signed entitlement smoke:** CI builds unsigned; microphone Audio Input entitlement embedding in a normally signed app remains a physical smoke test.
- Derived mix corruption is detected operationally by playback failure/fallback. Startup proactively detects a missing derived file but does not pre-decode every derived asset.
- The 0.5+0.5 mix gain is deterministic anti-clipping headroom, not loudness normalization.
- No physical disk-full test exists; writer/finalization errors follow the controlled preservation path.
- Missing derived mix regeneration is not yet exposed as a user action; originals, derivation IDs and offsets preserve enough data to regenerate later.

## Explicitly out of scope

Phase 4 contains no WhisperKit, SpeakerKit, transcription, diarization, VAD, summary, waveform, transcript editing, or other Phase 5+ functionality.

## Next phase

After PR #5 is merged, the next permitted phase is:

- **5 — Transcription**

Do not implement Phase 5 before Phase 4 integration.
