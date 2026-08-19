# Bardo Project State

## Current phase

1 — Library & Persistence

**Status:** PHASE_READY

Phase 0 is integrated and certified. Phase 1 is implemented and its code-bearing head passed the complete macOS build/test gate. This state-certification commit changes documentation only; the PR head is revalidated by CI after publication before the PR is marked ready for review.

## Integration status

- Phase 0 PR: #1 — `Phase 0 — Foundation` — merged.
- Phase 0 certified commit: `acbc8fe4584731b9c48fde2671226a91ee23d1af`.
- Phase 0 merge commit on `main`: `f4eacd251608cb1f8ae339b826fe3371f464c20d`.
- Phase 1 branch: `feat/phase-1-library-persistence`.
- Phase 1 PR: #2 — `Phase 1 — Library & Persistence`.

Inherited Foundation invariants remain in force: XcodeGen is the project source of truth, Bardo targets macOS 15+ with Swift 6 and SwiftUI, existing XCTest/CI stays green, and no future audio/AI dependency is introduced in Phase 1.

## Mission 1.1 — RecordingStore

**Status:** COMPLETE.

Demonstrated capabilities:

- Real disk persistence for `Recording` using stable UUID identity.
- Default live location: Application Support / Bardo / Library.
- Per-recording directory with `manifest.json`.
- Explicit operations for save, read, library reconstruction/list, update, and delete.
- Library reconstruction reads disk on each load; process memory is not the source of truth.
- Manifests are encoded before filesystem mutation begins.
- Replacement writes use a completed temporary file in the same recording directory followed by POSIX `rename(2)` to atomically replace the destination namespace entry.
- A failed encoding cannot replace an existing valid manifest.
- Multiple recordings coexist and a fresh store instance reconstructs them from disk.

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

`createdAtEpochSeconds` stores `Date.timeIntervalSince1970` without the second-rounding observed with standard ISO-8601 encoding, so normal `Date()` values survive a persistence round-trip without losing subsecond precision.

The on-disk manifest is a dedicated persistence type, not direct `Recording` Codable output. Future domain changes therefore cannot silently redefine the disk schema.

No migration framework exists yet. The loader reads `schemaVersion` first, accepts V1, and reports unsupported versions without modifying them.

### Atomicity boundary

The store guarantees atomic replacement of the manifest directory entry when the temporary file and destination are on the same filesystem, which they are by construction. Phase 1 does **not** claim power-loss durability or `fsync` semantics.

## Mission 1.2 — Library

**Status:** COMPLETE.

- `RootView` hosts the real recording Library.
- Native `NavigationSplitView` implementation.
- Sidebar displays title, date, duration, source, and processing state when available.
- Detail view exposes persisted recording metadata and UUID.
- Valid empty library is represented as an empty state, not an error.
- Selection is reconciled against recordings freshly loaded from disk.
- Global read failures are surfaced without silently discarding already-visible data.
- Recovery issues are surfaced separately from healthy recordings.
- If all stored entries are defective, the Library shows an explicit recovery state rather than a false empty state.
- SwiftUI does not know internal paths, filenames, JSON, or filesystem operations.
- No production sample recordings or fake audio pipeline exists; fixtures live only in tests.

## Mission 1.3 — Recovery

**Status:** COMPLETE.

Recovery policy:

`preserve → detect → report → continue loading healthy data`

Controlled cases:

- corrupt/un-decodable `manifest.json`;
- incomplete V1 manifest;
- unsupported `schemaVersion`;
- UUID directory / manifest identity mismatch;
- missing final manifest;
- residual `.manifest-*.tmp` interrupted-write artifacts;
- unexpected library entries;
- a normal `Recording` with no transcript.

Per-recording failures become `RecordingStoreIssue` values. They do not abort the whole library load and Bardo does not delete the defective entry automatically.

The integrated A-valid / B-corrupt / C-valid scenario demonstrates that A and C remain recoverable while B is detected and preserved and the Library stays stable.

## Tests

The macOS Phase 1 gate executes **16 XCTest cases with 0 failures**:

- Phase 0 bootstrap regression: 1 test.
- Phase 0 domain Codable regressions: 2 tests.
- Library state/restart representation: 2 tests.
- Phase 1 integrated restart/recovery flow: 1 test.
- Recording recovery scenarios: 6 tests.
- RecordingStore persistence/update/delete/atomic-failure behavior: 4 tests.

Key demonstrated scenarios include:

- save/read preserves UUID and all persisted fields;
- `schemaVersion == 1` is present;
- fractional `createdAt` precision survives round-trip;
- multiple recordings coexist;
- fresh store reconstruction works;
- update and delete have explicit semantics;
- invalid JSON encoding does not overwrite a valid manifest;
- empty Library is valid;
- fresh store + fresh view model represent persisted state after simulated restart;
- corrupt and incomplete manifests are isolated and preserved;
- unsupported schema versions are preserved;
- interrupted-write temporary residue is detected without replacing a valid manifest;
- recording without transcript is valid;
- A valid / B corrupt / C valid leaves A and C usable and B controlled.

## CI evidence

GitHub Actions run `32288468995` validated the code-bearing Phase 1 head on:

- macOS 15.7.7 Apple Silicon runner;
- Xcode 16.4 (build 16F6);
- Apple Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0.

Observed results:

- checkout: passed;
- XcodeGen installation: passed;
- `xcodegen generate`: passed;
- Debug `xcodebuild ... build`: **BUILD SUCCEEDED**;
- `Bardo.app` Info.plist and executable verification: passed;
- `xcodebuild ... test`: **TEST SUCCEEDED**;
- 16 tests executed, 0 failures.

No Swift compiler warning attributable to Phase 1 appeared in the inspected log. The remaining warnings are runner/toolchain noise already seen in Foundation: Homebrew reports an unrelated preinstalled untrusted tap, and Xcode's metadata processor reports that AppIntents extraction is skipped because Bardo does not depend on AppIntents.

The documentation-only certification head is required to pass the same PR workflow before external review.

## Additional validation

- Phase 0 integration and merge ancestry verified on GitHub.
- Phase 1 branch originates from updated `main` at `f4eacd251608cb1f8ae339b826fe3371f464c20d`.
- Persistence/domain sources pass `swiftc -swift-version 6 -typecheck` with Swift 6.2.1 on Linux.
- RecordingStore and recovery XCTest sources typecheck against an `-enable-testing` Bardo module on Linux.
- SwiftUI / view-model / integration test sources pass `swiftc -parse` outside macOS; full macOS compilation is demonstrated by CI.
- A real command-line harness exercised save → update → read → corrupt-neighbor recovery successfully after the atomic-write repair.
- Full diff against `main` reviewed: only Phase 1 feature, persistence, test, and documentation files changed; no Phase 2 implementation is present.

## Reviewer findings repaired

- Replaced `FileManager.replaceItemAt` after a real execution exposed unreliable replacement behavior in the test environment; same-directory POSIX `rename(2)` now performs the atomic replacement.
- Prevented loss of subsecond `createdAt` precision caused by standard ISO-8601 encoding.
- Added explicit Library recovery state when every stored item is defective.
- Added visible global reload error state when previously loaded recordings remain on screen.
- Added explicit Foundation import for formatting helpers.
- Removed unused `LibrarySnapshot.empty` state.
- Re-reviewed after macOS CI; no additional material issue was found.

## Storage invariants

- UUID directory identity is stable and checked against manifest identity.
- `manifest.json` V1 is the current persisted metadata source of truth.
- In-memory Library state is derived from the store and may always be rebuilt from disk.
- A per-recording failure cannot abort loading other recordings.
- Defective or unknown data is preserved by default rather than silently deleted.
- Temporary write artifacts never supersede a valid final manifest.
- Schema versions unknown to this build are reported, not migrated or destroyed.
- Domain/UI code does not depend on concrete storage paths or JSON structure.

## Data and migrations

Current persisted schema: **1**.

There are no migrations. Unsupported versions are detected and preserved for future recovery/migration work.

No transcript is required for a stored recording in Phase 1.

## Known minor debt / evidence pending

- **PARTIAL — visual UI inspection:** an interactive human has not visually inspected the Library window in this execution. Xcode compiles the SwiftUI hierarchy, the app launches as the XCTest host, `RootView` constructs, and Library state behavior is covered by tests, so this does not block Phase 1.
- Persistence does not claim crash/power-loss durability beyond same-filesystem atomic namespace replacement; explicit `fsync` durability is not part of Phase 1.
- User-facing recovery actions beyond detection/reporting are intentionally deferred; Phase 1 never silently deletes defective evidence.

## Out of scope and absent

Phase 1 contains no real audio import, microphone capture, ScreenCaptureKit, WhisperKit, SpeakerKit, transcription, diarization, AI processing, or audio-processing placeholder architecture.

## Next phase

After PR #2 is reviewed and merged, the next permitted phase is:

- **2 — Importar audio**

Do not implement Phase 2 before Phase 1 integration.
