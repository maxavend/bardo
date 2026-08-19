# Bardo Project State

## Current phase

2 — Audio Import

**Status:** VALIDATING

Phase 0 and Phase 1 are integrated and certified. Phase 2 implementation is complete on `feat/phase-2-audio-import` and is awaiting the full macOS/Xcode CI gate before `PHASE_READY` can be claimed.

## Integrated baseline

- Phase 0 — Foundation: certified and merged.
- Phase 1 — Library & Persistence: certified and merged via PR #2.
- Phase 1 merge commit on `main`: `8e6ad83377aa4ae75e47bea394a7a20516adf870`.
- Phase 2 branch: `feat/phase-2-audio-import`, created exactly from that merge commit.
- Platform invariants: macOS 15+, Swift 6, SwiftUI, XcodeGen, no runtime third-party dependencies.

## Mission 2.1 — File Importer

**Implementation status:** COMPLETE — awaiting final macOS CI evidence.

Implemented behavior:

- Native SwiftUI file importer.
- Native drag & drop of file URLs.
- Explicit accepted extensions in the import service: `.m4a`, `.mp3`, `.wav`, `.flac`, `.aac`, `.aiff`.
- Extension is only a first gate; AVFoundation must successfully interpret the resource as audio before storage mutation begins.
- Each successful import creates a new `Recording` and `AudioAsset` UUID, so importing the same source twice intentionally creates independent recordings. No hash deduplication exists in Phase 2.
- Security-scoped access is used when supplied by macOS and relinquished after the import attempt.
- The original file is never moved, renamed, deleted, or used as the durable playback location.

### Managed storage transaction

Current structure:

```text
Library/
└── <recording-uuid>/
    ├── manifest.json
    └── audio/
        └── <audio-asset-uuid>.<ext>
```

Import order:

```text
validate audio + metadata
→ encode manifest in memory
→ create new recording directory
→ copy original to audio/.audio-<uuid>.tmp
→ same-directory rename to final managed audio name
→ atomically publish manifest
```

If the copy or manifest publication fails, Bardo attempts to remove only the newly created recording directory. The external original is never touched. If cleanup itself cannot complete, residue is left for recovery rather than deleting unrelated evidence.

A portable transaction harness has demonstrated:

`copy → managed file → delete original → fresh store → managed file remains resolvable`.

It also demonstrated that a missing source/copy failure does not publish a valid recording into the Library.

## Mission 2.2 — Audio Metadata

**Implementation status:** COMPLETE — awaiting final macOS CI evidence.

`AudioAsset` owns technical audio metadata rather than leaking AVFoundation concepts into `Recording`:

- duration;
- codec/format label when a reliable Core Audio format identifier is available;
- sample rate;
- channel count;
- original file name as informational metadata only;
- normalized file extension used to resolve the managed resource.

For a Phase 2 single-file import, `Recording.duration` mirrors the imported asset duration as the existing recording-level summary field.

### Manifest schema

Current write schema: **2**.

Schema 2 persists the previous recording fields plus audio asset identity and metadata. New writes use V2. Existing schema 1 manifests remain readable and reconstruct recordings with `audioAssets = []`; they are not destructively migrated or deleted. Unknown future schema versions continue to be reported and preserved.

The managed filesystem path itself is not persisted in Domain or exposed to SwiftUI. `RecordingStore` derives it from recording identity, audio asset identity, and the persisted extension.

## Mission 2.3 — Playback

**Implementation status:** COMPLETE — awaiting final macOS CI evidence.

`AudioPlaybackController` uses native AVFoundation playback and exposes only UI-facing state:

- load managed audio;
- play;
- pause;
- seek/scrub;
- current position;
- total duration;
- controlled playback error state.

The progress task exists only while playback is active. It is cancelled on pause, unload, selection change, end-of-file detection, and Library disappearance. Switching recordings unloads the previous player before resolving the next managed resource.

Library displays persisted audio metadata and simple native playback controls. No waveform, editing, transcript synchronization, or polish-phase redesign is included.

## Recovery

The inherited policy remains:

`preserve → detect → inform → continue`

Phase 2 adds controlled detection for:

- valid manifest + missing managed audio;
- interrupted `.audio-*.tmp` import residue;
- corrupt manifest + existing audio evidence;
- missing/corrupt audio encountered by playback.

A manifest with a missing managed audio file remains loadable as a recording and receives a recovery issue. Corrupt manifests continue to isolate only their own recording directory; existing audio evidence is not silently deleted.

## Tests authored for Phase 2

- `AudioImportTests`: supported extension contract, real generated WAV import, technical metadata, schema 2 persistence, managed-copy independence from the original, unsupported extension, fake audio contents, copy failure rollback, V1 compatibility.
- `AudioRecoveryTests`: missing managed audio, interrupted audio temp residue, corrupt manifest with preserved audio evidence.
- `AudioPlaybackControllerTests`: load/play/pause/seek/end state plus missing/corrupt playback errors.
- `Phase2IntegrationTests`: import → delete original → fresh store/view model → Library reconstruction → managed playback load/play/pause.
- `AudioTestFixture`: tiny deterministic WAV files generated at test runtime; no network and no multimedia binaries committed.
- Existing Foundation/Phase 1 tests remain in the suite; `RecordingStoreTests` now expects schema 2 for new writes.

## Validation before PR CI

- Full planned Swift source tree parses with the available Swift toolchain.
- Domain + Persistence pass Swift 6 typechecking outside macOS.
- Portable store transaction harness passes managed-copy independence and failed-copy isolation.
- Branch diff reviewed against `main`: only Phase 2 audio/domain/persistence/Library/test/documentation work is present; no Phase 3 capability is included.

Full AVFoundation, SwiftUI, XcodeGen, application build and XCTest validation require the existing macOS 15 / Xcode 16.4 CI and remain **PENDING** at this state.

## Storage invariants

- Process memory is not the source of truth.
- The external source path is not the durable audio dependency.
- A successful import owns a managed copy under the recording UUID.
- Recording and audio asset UUIDs are stable persisted identity.
- New manifests use schema 2; schema 1 remains readable.
- UI does not know JSON or concrete Application Support paths.
- A single defective recording or audio resource cannot abort loading healthy neighbors.
- Recovery never automatically deletes corrupt manifests, unknown schemas, or suspicious audio evidence.
- Atomicity claims are limited to same-filesystem namespace replacement; Phase 2 does not claim `fsync`/power-loss durability.

## Reviewer focus before certification

Before `PHASE_READY`, reject the implementation if CI/review finds: external-path dependence, false-valid imports, orphaning under ordinary failures, extension-only validation, lost metadata, V1 regression, unmanaged playback lifecycle, bad seek/end state, UI/filesystem coupling, oversized fixtures, Phase 3 leakage, or a Phase 0/1 regression.

## Known minor debt / evidence pending

- **PARTIAL — visual UI inspection:** a human interactive inspection of picker/drop/playback layout is still pending; automated macOS compilation and state tests are the phase gate.
- Playback UI uses the first managed audio asset. Phase 2 imports exactly one asset per recording; generalized multi-source playback is intentionally not implemented yet.
- Audio corruption is validated on import and again when playback opens the managed file; the Library does not decode every audio file on every reload merely to recompute persisted metadata.
- No hash-based duplicate detection exists by design.

## Explicitly out of scope

Phase 2 contains no microphone capture, ScreenCaptureKit, WhisperKit, SpeakerKit, transcription, diarization, VAD, AI processing, export, transcript editing, waveform editing, or Phase 3 implementation.

## Next phase

Only after Phase 2 reaches `PHASE_READY`, is reviewed, and its PR is merged, the next permitted phase is:

- **3 — Grabación de micrófono**

Do not implement Phase 3 before Phase 2 integration.
