# Bardo Project State

## Current phase

2 — Audio Import

**Status:** PHASE_READY

Phase 0 and Phase 1 remain integrated and certified. Phase 2 is fully implemented on `feat/phase-2-audio-import`; its code-bearing head `d4997ffea6ef88b3f11f9b714206967859264678` passed the complete macOS build/test gate before this documentation-only certification commit.

## Integrated baseline

- Phase 0 — Foundation: certified and merged.
- Phase 1 — Library & Persistence: certified and merged via PR #2.
- Phase 1 merge commit on `main`: `8e6ad83377aa4ae75e47bea394a7a20516adf870`.
- Phase 2 branch: `feat/phase-2-audio-import`, created exactly from that merge commit.
- Phase 2 PR: #3 — `Phase 2 — Audio Import`.
- Platform invariants remain: macOS 15+, Swift 6, SwiftUI, XcodeGen, no runtime third-party dependencies.

## Mission 2.1 — File Importer

**Status:** COMPLETE.

- Native SwiftUI file importer and native drag & drop.
- Accepted extensions: `.m4a`, `.mp3`, `.wav`, `.flac`, `.aac`, `.aiff`.
- Extension is only a first gate; AVFoundation must successfully open the resource as audio before storage mutation begins.
- CI positively exercises a real generated WAV fixture and negatively verifies that invalid `.mp3` contents are rejected. The remaining accepted extensions rely on AVFoundation readability at runtime rather than extension trust alone.
- Successful imports create a fresh `Recording` and `AudioAsset`, then copy the source into Bardo-managed storage.
- The original source is never moved or deleted and is not the durable playback dependency.
- Importing the same source twice intentionally creates two independent recordings; no hash deduplication is implemented.

### Managed storage transaction

```text
Library/
└── <recording-uuid>/
    ├── manifest.json
    └── audio/
        └── <audio-asset-uuid>.<ext>
```

Successful import order:

```text
validate + read metadata
→ encode manifest in memory
→ create fresh recording directory
→ copy to audio/.audio-<uuid>.tmp
→ same-directory rename to final managed audio file
→ atomically publish manifest
```

A copy or publication failure does not expose a false-valid recording. Bardo attempts to remove only the directory created for that failed import; the external source remains untouched. If cleanup itself cannot complete, residue is preserved for recovery.

## Mission 2.2 — Audio Metadata

**Status:** COMPLETE.

Technical metadata belongs to `AudioAsset` / `AudioMetadata`, not to AVFoundation-specific domain APIs:

- duration;
- codec/format label when a reliable Core Audio identifier is available;
- sample rate;
- channel count;
- original file name as informational metadata;
- normalized file extension for resolving the managed resource.

For the single imported asset supported in Phase 2, `Recording.duration` mirrors the asset duration as the recording-level summary.

### Manifest schema

Current write schema: **2**.

Schema 2 retains Phase 1 recording metadata and adds audio asset identity and technical metadata. Exact arbitrary `Date` values are reconstructed using the persisted IEEE-754 bit pattern of the epoch-seconds value after CI exposed that JSON floating-point round-trips can otherwise lose bit-level equality.

Schema 1 remains readable and reconstructs with `audioAssets = []`; no destructive migration occurs. Unknown future schema versions continue to be detected, reported, and preserved.

Absolute managed paths are not persisted in Domain. `RecordingStore` derives the resource location from recording UUID, audio asset UUID, and extension.

## Mission 2.3 — Playback

**Status:** COMPLETE.

`AudioPlaybackController` uses native `AVAudioPlayer` and supports:

- load managed audio;
- play;
- pause while retaining position;
- seek/scrub;
- resume;
- current position and total duration;
- coherent natural end state;
- controlled missing/corrupt/unavailable audio errors.

The progress task exists only during active playback and is cancelled on pause, unload, natural completion, selection replacement, and Library disappearance. Loading another recording stops and resets the previous player.

A macOS-specific behavior discovered by CI was repaired: `AVAudioPlayer` may rewind `currentTime` to zero after natural completion, so Bardo now preserves the UI end position as total duration when active playback transitions to stopped.

A persisted recording with no managed audio remains a valid Library item; playback reports unavailable without destabilizing the Library.

## Recovery

Inherited policy remains:

`preserve → detect → inform → continue`

Phase 2 covers:

- valid manifest + valid managed audio;
- valid manifest + missing managed audio;
- valid manifest + corrupt managed audio;
- corrupt manifest + existing audio evidence;
- interrupted `.audio-*.tmp` residue;
- recordings without managed audio.

Missing managed audio is reported without hiding the recording. Corrupt managed audio leaves the Library stable and fails playback in a controlled way. Corrupt manifests do not cause existing audio evidence to be deleted. Temporary import residue is preserved and reported.

## Integrated gate

Automated tests demonstrate the complete Phase 2 ownership flow:

```text
external valid WAV
→ validate with AVFoundation
→ extract metadata
→ copy into Bardo-managed storage
→ persist schema 2 manifest
→ rebuild Library
→ load managed playback
→ play / pause / seek / resume / finish coherently
```

The critical independence scenario is also demonstrated:

```text
import external audio
→ delete ORIGINAL
→ create fresh RecordingStore
→ create fresh LibraryViewModel
→ recording reloads from disk
→ managed audio remains available
→ playback loads and plays from Bardo's internal copy ✅
```

Process memory and the external source path are therefore not the source of truth.

## Tests and CI evidence

Final code-bearing GitHub Actions run `32294495102` validated commit `d4997ffea6ef88b3f11f9b714206967859264678` on:

- macOS 15.7.7 Apple Silicon;
- Xcode 16.4 (16F6);
- Apple Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0.

Observed results:

- checkout: passed;
- XcodeGen install: passed;
- `xcodegen generate`: passed;
- Debug build: **BUILD SUCCEEDED**;
- app bundle/executable verification: passed;
- XCTest: **TEST SUCCEEDED**;
- **32 tests executed, 0 failures**.

The suite includes all Foundation/Phase 1 regressions plus real generated-audio import, metadata, V1 compatibility, failed-copy isolation, missing/corrupt audio recovery, temp import residue, playback lifecycle, selection replacement, recording-without-audio behavior, and the full restart/original-deletion integrated gate.

No material Swift compiler warning attributable to Phase 2 appears in the inspected log. Non-material runner/framework diagnostics include the unrelated Homebrew tap-trust notice, AppIntents metadata-skip notices because Bardo does not use AppIntents, AVFoundation diagnostics intentionally emitted while opening corrupt test audio, and virtual-runner audio-device diagnostics.

This documentation-only certification head must pass the same PR workflow before PR #3 is marked ready for external review.

## Reviewer findings repaired

The global reviewer / CI loop found and repaired:

- exact timestamp fidelity for arbitrary `Date()` values in schema 2;
- AVAudioPlayer natural-completion rewind causing the UI position to return to zero;
- an overly strict fixed playback timing assumption in the virtual runner while preserving the end-state assertion;
- an invalid async XCTest autoclosure in the integration test;
- opaque whole-`Recording` equality assertions replaced with an explicit persisted-field contract;
- explicit coverage for corrupt managed audio;
- explicit coverage for player replacement when selection changes;
- explicit coverage for valid recordings with no managed audio.

The full diff against `main` was re-reviewed after repairs: Phase 2 is ahead of its merge base only, introduces no new runtime dependency, and contains no Phase 3 implementation.

## Storage and import invariants

- Process memory is not the source of truth.
- The external source path is not the durable audio dependency.
- Successful imports own a managed audio copy under the recording UUID.
- Recording and audio asset UUIDs are stable persisted identities.
- New writes use schema 2; schema 1 remains readable.
- SwiftUI does not know JSON or concrete Application Support paths.
- A single defective recording/audio resource cannot abort healthy neighbors.
- Suspicious/corrupt evidence is preserved rather than silently deleted.
- Temporary import artifacts never supersede a final managed resource.
- Atomicity claims are limited to same-filesystem namespace replacement; no `fsync`/power-loss durability guarantee is claimed.

## Known minor debt / evidence pending

- **PARTIAL — interactive visual inspection:** a human has not visually inspected picker, drag/drop, metadata and playback layout in this execution. macOS compilation, app-host launch, view construction and behavior tests are green, so this does not block Phase 2.
- Positive CI media coverage uses a deterministic generated WAV fixture; the six accepted extensions are gated by AVFoundation readability, but CI does not contain a positive fixture for every codec/container combination.
- Playback UI currently uses the first managed audio asset. Phase 2 imports exactly one asset per recording; generalized multi-source playback is intentionally deferred.
- No hash-based duplicate detection exists by design.
- Library reload checks managed-file existence but does not decode every audio resource on every launch; corrupt content is detected when AVFoundation opens it for playback.
- No explicit `fsync` durability is claimed beyond same-filesystem atomic rename semantics.

## Explicitly out of scope

Phase 2 contains no microphone capture, ScreenCaptureKit, WhisperKit, SpeakerKit, transcription, diarization, VAD, AI processing, export, transcript editing, waveform editing, or Phase 3 implementation.

## Next phase

After PR #3 is reviewed and merged, the next permitted phase is:

- **3 — Grabación de micrófono**

Do not implement Phase 3 before Phase 2 integration.
