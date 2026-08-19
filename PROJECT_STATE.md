# Bardo Project State

## Current phase

1 — Library & Persistence

**Status:** VALIDATING

Phase 0 is integrated and certified. Phase 1 implementation is complete on `feat/phase-1-library-persistence`; macOS CI on the phase PR is still required before `PHASE_READY` can be claimed.

## Integrated baseline

- Phase 0 PR: #1 — `Phase 0 — Foundation`
- Phase 0 certified commit: `acbc8fe4584731b9c48fde2671226a91ee23d1af`
- Phase 0 merge commit on `main`: `f4eacd251608cb1f8ae339b826fe3371f464c20d`
- Phase 1 branch: `feat/phase-1-library-persistence`

Inherited Foundation invariants remain in force: XcodeGen is the project source of truth, Bardo targets macOS 15+ with Swift 6 and SwiftUI, existing XCTest/CI stays green, and no future audio/AI dependency is introduced in Phase 1.

## Mission 1.1 — RecordingStore

**Implementation status:** COMPLETE — awaiting final macOS CI evidence.

Capabilities implemented:

- Real disk persistence for `Recording` using stable UUID identity.
- Default live location: Application Support / Bardo / Library.
- Per-recording directory with `manifest.json`.
- Explicit operations for save, read, list/rebuild, update, and delete.
- Library reconstruction reads disk on each load; process memory is not the source of truth.
- Manifests are encoded before filesystem mutation begins.
- Replacement writes use a completed temporary file in the same recording directory followed by POSIX `rename(2)` to atomically replace the destination namespace entry.
- A failed encoding cannot replace an existing valid manifest.

### Persistent format — schemaVersion 1

Conceptual layout:

```text
Library/
└── <recording-uuid>/
    └── manifest.json
```

Current manifest fields:

```text
schemaVersion: 1
id: UUID
title: String
createdAtEpochSeconds: Double
duration: Double? 
sources: [AudioSource]
processingState: ProcessingState
```

`createdAtEpochSeconds` deliberately stores the exact `Date.timeIntervalSince1970` value rather than second-rounded ISO-8601 text, so normal `Date()` values survive a persistence round-trip without losing subsecond precision.

The on-disk manifest is a dedicated persistence type, not direct `Recording` Codable output. This prevents future domain changes from silently changing the disk schema.

No migration framework exists yet. The loader reads `schemaVersion` first, accepts V1, and reports unsupported versions without modifying them.

### Atomicity boundary

The store guarantees atomic replacement of the manifest directory entry when the temporary file and destination are on the same filesystem, which they are by construction. Phase 1 does **not** claim power-loss durability or `fsync` semantics.

## Mission 1.2 — Library

**Implementation status:** COMPLETE — awaiting final macOS CI evidence.

- `RootView` now hosts the real recording Library.
- Native `NavigationSplitView` implementation.
- Sidebar displays title, date, duration, source, and processing state when available.
- Detail view exposes persisted recording metadata and UUID.
- Valid empty library is represented as an empty state, not an error.
- Selection is reconciled against records freshly loaded from disk.
- Global read failures are surfaced without silently discarding already-visible data.
- Recovery issues are surfaced separately from healthy recordings.
- SwiftUI does not know internal paths, filenames, JSON, or filesystem operations.
- No production sample recordings or fake audio pipeline exists; fixtures live only in tests.

## Mission 1.3 — Recovery

**Implementation status:** COMPLETE — awaiting final macOS CI evidence.

Recovery policy:

`preserve → detect → report → continue loading healthy data`

Controlled cases implemented:

- corrupt/un-decodable `manifest.json`;
- incomplete V1 manifest;
- unsupported `schemaVersion`;
- UUID directory / manifest identity mismatch;
- missing final manifest;
- residual `.manifest-*.tmp` interrupted-write artifacts;
- unexpected library entries;
- a normal `Recording` with no transcript.

Per-recording failures become `RecordingStoreIssue` values. They do not abort the whole library load and Bardo does not delete the defective entry automatically.

If healthy and defective recordings coexist, healthy recordings remain loadable. If every stored recording is defective, the Library shows an explicit recovery state instead of pretending the library is empty.

## Tests authored for Phase 1

### RecordingStoreTests

- save/read round-trip preserves UUID and all persisted fields;
- verifies `schemaVersion == 1`;
- fractional `createdAt` precision survives round-trip;
- multiple recordings coexist;
- a fresh `RecordingStore` reconstructs state from disk;
- update replaces persisted metadata;
- delete has explicit semantics;
- invalid JSON encoding cannot overwrite a previously valid manifest.

### LibraryViewModelTests

- empty disk state is valid;
- a fresh view model backed by a fresh store instance represents persisted recordings after simulated restart.

### RecordingStoreRecoveryTests

- A valid / B corrupt / C valid isolation;
- incomplete manifest detection and preservation;
- unsupported schema detection and preservation;
- valid manifest plus temporary residue;
- temporary-only incomplete recording;
- recording without transcript is valid.

### Phase1IntegrationTests

Exercises the phase-level flow with fresh process-equivalent instances:

```text
persist A + C
create corrupt B
↓
new RecordingStore
↓
new LibraryViewModel
↓
A + C represented
B reported as corrupt
application state remains stable
```

## Validation completed before PR CI

- Phase 0 integration and merge ancestry verified on GitHub.
- Phase 1 branch confirmed to originate from updated `main` at `f4eacd251608cb1f8ae339b826fe3371f464c20d`.
- Persistence/domain sources pass `swiftc -swift-version 6 -typecheck` with Swift 6.2.1 on Linux.
- RecordingStore and recovery XCTest sources typecheck against an `-enable-testing` Bardo module on Linux.
- SwiftUI / view-model / integration test sources pass `swiftc -parse`.
- A real command-line harness exercised save → update → read → corrupt-neighbor recovery successfully after the atomic-write repair.

## Reviewer findings already repaired

- Replaced `FileManager.replaceItemAt` after a real execution exposed unreliable replacement behavior in this environment; same-directory POSIX `rename(2)` now performs the atomic replacement.
- Prevented loss of subsecond `createdAt` precision caused by standard ISO-8601 encoding.
- Added explicit Library recovery state when every stored item is defective.
- Added visible global reload error state when previously loaded recordings remain on screen.
- Added explicit Foundation import for formatting helpers.
- Removed unused `LibrarySnapshot.empty` state.

## CI

Final Phase 1 pull-request CI: **PENDING**.

Before `PHASE_READY`, the phase head must demonstrate on the existing macOS 15 / Xcode 16.4 workflow:

- XcodeGen generation succeeds;
- Debug build succeeds;
- application bundle verification succeeds;
- all XCTest cases pass;
- no material warnings/errors or Phase 0 regression appears.

## Data and migrations

Current persisted schema: **1**.

There are no migrations. Unsupported versions are detected and preserved for future recovery/migration work.

No transcript is required for a stored recording in Phase 1.

## Known minor debt / evidence pending

- Visual inspection of the Library window on an interactive Mac is `PARTIAL`; automated build/view construction and model-state tests are the required gate for this phase.
- Persistence does not claim crash/power-loss durability beyond same-filesystem atomic namespace replacement; explicit `fsync` durability is not part of Phase 1.
- User-facing recovery actions beyond detection/reporting are intentionally deferred; Phase 1 never silently deletes defective evidence.

## Out of scope and absent

Phase 1 contains no real audio import, microphone capture, ScreenCaptureKit, WhisperKit, SpeakerKit, transcription, diarization, AI processing, or audio-processing placeholder architecture.

## Next phase

After Phase 1 reaches `PHASE_READY`, is reviewed, and its PR is merged, the next permitted phase is:

- **2 — Importar audio**

Do not implement Phase 2 before Phase 1 integration.
