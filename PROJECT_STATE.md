# Bardo Project State

## Current phase

7 — Transcript UX

**Status:** PHASE_READY, conditional on the exact documentation head containing this statement passing the same full CI gate. PR #9 must remain draft until that condition is satisfied.

Phases 0–6 are integrated on `main`. Phase 6 was merged through PR #8 with merge commit `7649e1a4a2fc8e633855978865b6d47c3a8547f4`; `feat/phase-7-transcript-ux` was created exactly from that commit.

The Phase 7 production/reviewer head `61021ef2413b8fe1b6503642d7a595526f775207` passed GitHub Actions run `33004680056` (CI #114) with XcodeGen generation, entitlement/configuration checks, Debug build, application bundle verification and **109 XCTest cases with 0 failures**. Documentation-only commits after that head must pass the same full CI before PR #9 is marked ready for review.

## Integrated baseline

- Phase 0 — Foundation: merged and certified.
- Phase 1 — Library & Persistence: merged via PR #2.
- Phase 2 — Audio Import: merged via PR #3.
- Phase 3 — Microphone Recording: merged via PR #4.
- Phase 4 — System Audio: merged and certified.
- Phase 5 — Transcription: merged via PR #7.
- Phase 6 — Diarization: merged via PR #8.
- Phase 6 merge / Phase 7 branch base: `7649e1a4a2fc8e633855978865b6d47c3a8547f4`.
- Phase 7 branch: `feat/phase-7-transcript-ux`.
- Phase 7 PR: #9 — `Phase 7 — Transcript UX`.
- Platform: macOS 15+, Swift 6, SwiftUI, XcodeGen.
- Recording manifest write schema remains **3**.
- Transcript write schema remains **1**.

## Mission 7.1 — Conversational transcript presentation

**Status:** COMPLETE.

The recording detail no longer presents the transcript as one undifferentiated block. It now renders the existing durable transcript as timestamped conversational turns while preserving the underlying Phase 5/6 segment structure.

Each visible turn provides:

- the assigned speaker label when diarization exists;
- `Transcript` for non-diarized content;
- `Unassigned speaker` when diarization has no temporal evidence for that segment;
- a timestamp control that seeks playback to the segment start;
- selectable transcript text;
- a segment-edit action;
- an explicit marker when the visible text contains a manual correction.

Transcript-level controls add:

- search by visible transcript text;
- search by the current speaker label/name;
- copy-all using the human-readable transcript representation;
- compact language/speaker-count context;
- collapsible engine/model metadata rather than making inference provenance dominate the reading experience.

No transcript turn splitting or reconstruction is invented. The Phase 6 segment boundaries remain authoritative; Phase 7 improves presentation and correction without fabricating more precise speaker-turn segmentation than the durable data supports.

## Mission 7.2 — Persistent speaker naming

**Status:** COMPLETE.

Phase 7 activates the already-existing optional `Speaker.name` field instead of creating a parallel naming model or changing transcript schema.

- Clicking an assigned speaker label opens a naming editor.
- A non-empty trimmed name replaces the automatic `Speaker 1`, `Speaker 2`, ... presentation.
- Saving a blank name restores the automatic label.
- Names are persisted through the existing `TranscriptStore` durability boundary.
- A fresh `LibraryViewModel` / `TranscriptStore` reconstructs the assigned name from disk.
- Naming is blocked while transcription or diarization is active so edit publication cannot race model work.

Speaker names are attached to the current durable speaker IDs, not audio embeddings or hidden model objects.

## Mission 7.3 — Non-destructive transcript corrections

**Status:** COMPLETE.

Human correction is deliberately separated from generated evidence.

`TranscriptSegment` now has an optional additive field:

```text
text             # original Whisper text, preserved
words            # original word timestamps/probabilities, preserved
editedText?      # optional human correction
      ↓
displayText      # editedText ?? text
```

The following invariants are enforced:

- original Whisper text is never overwritten by a Phase 7 edit;
- segment IDs, start/end bounds and word timestamps remain unchanged;
- `Transcript.text`, on-screen reading, search and copy-all use `displayText`;
- an edit identical to the trimmed original collapses back to `editedText = nil`;
- an empty/whitespace-only edit is rejected rather than turning a segment into false blank content;
- `Restore Original` removes only `editedText` and immediately exposes the preserved generated text again;
- edit persistence uses the same atomic `TranscriptStore` publication path as transcription/diarization.

Transcript schema remains **V1**. `editedText` is optional/additive, and automated compatibility proves a Phase 5/6 V1 segment with no `editedText` still decodes and displays its original text.

## Mission 7.4 — Replacement safety for manual work

**Status:** COMPLETE.

The reviewer pass identified two destructive replacement paths that become materially different once Phase 7 allows human changes.

### Re-transcription

A successful `Transcribe Again` creates a new generated transcript and therefore replaces manual text corrections and speaker names in the current transcript. Phase 7 now detects manual changes and requires explicit confirmation before starting that replacement.

Manual-change detection distinguishes:

- `hasManualTextEdits`;
- `hasNamedSpeakers`;
- combined `hasManualChanges`.

### Re-diarization

SpeakerKit re-diarization may produce a new set/order of speaker clusters. Carrying names forward by `Speaker 1`/array position would therefore risk assigning a real person's name to a different voice.

Phase 7 intentionally rejects that unsafe shortcut:

- manual text corrections are preserved through re-diarization because Phase 6 alignment mutates the existing transcript segments rather than rebuilding their text;
- manually named speakers trigger a confirmation before `Identify Speakers Again`;
- after confirmation, new speaker clusters receive fresh automatic names rather than guessing identity continuity across inference runs.

This preserves data honesty over apparent convenience.

## Mission 7.5 — Durable edit lifecycle

**Status:** COMPLETE.

Manual transcript changes reuse the established durability boundary rather than introducing view-only state as the source of truth.

```text
current durable transcript
→ create edited value in memory
→ TranscriptStore same-directory temp write
→ atomic rename publication
→ update visible transcript only after save succeeds
```

Consequences:

- a failed edit save leaves the previously valid transcript authoritative;
- no partial speaker name or partial text correction is published to the final file;
- a fresh process/view model reconstructs saved names/corrections;
- transcription, diarization and manual editing remain mutually exclusive where their state transitions could race;
- managed audio is never mutated by transcript UX work.

## Integrated automated gate

Phase 7 deterministic coverage includes:

```text
legacy Transcript V1 without editedText decodes ✅
legacy segment displays original generated text ✅
manual correction round-trip through TranscriptStore ✅
original raw text survives correction ✅
original word timestamps/probabilities survive correction ✅
segment bounds survive correction ✅
speaker rename persists ✅
fresh LibraryViewModel reconstructs speaker name + text correction ✅
restore-original removes only editedText ✅
blank speaker name restores automatic naming state ✅
blank transcript edit is rejected without disk mutation ✅
manual text/name change detection ✅
all inherited Phase 0–6 regressions ✅
```

The application itself also compiles the complete conversational SwiftUI surface, edit sheets, confirmation alerts, WhisperKit and SpeakerKit production boundaries in the same CI gate.

## CI evidence

GitHub Actions run `33004680056` (CI #114), production/reviewer head `61021ef2413b8fe1b6503642d7a595526f775207`:

- macOS 15.7.7 Apple Silicon runner;
- Xcode 16.4 (16F6);
- Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0;
- exact Argmax OSS package resolution: **1.0.0**;
- explicit Bardo target dependencies remain `WhisperKit` + `SpeakerKit`;
- microphone entitlement: passed;
- outbound network client entitlement: passed;
- XcodeGen generation: passed;
- Debug build: **BUILD SUCCEEDED**;
- application bundle/privacy verification: passed;
- XCTest: **TEST SUCCEEDED**;
- **109 tests executed, 0 failures**.

CI does not claim visual interaction quality merely because SwiftUI compiles. Search/readability, editor ergonomics, confirmation copy, timestamp-seek feel and long-transcript scanning remain appropriate interactive smoke evidence.

## Reviewer findings and repairs

The Builder/Reviewer loop materially changed Phase 7 before certification:

1. Kept human text correction separate from Whisper's original `text`/word timestamps instead of destructively replacing generated evidence.
2. Reused the existing durable optional `Speaker.name` rather than inventing a second speaker-name persistence model.
3. Routed manual changes through `TranscriptStore` atomic publication and updated UI state only after successful persistence.
4. Repaired Swift 6 XCTest async/autoclosure usage exposed while adding fresh-store edit-persistence tests.
5. Verified that Phase 6 re-diarization mutates the existing transcript, so `editedText` survives speaker re-identification without custom reconstruction.
6. Found that successful re-transcription would replace manual corrections/names and added an explicit destructive confirmation gate.
7. Found that re-diarization creates fresh speaker objects and rejected unsafe name carry-over by cluster ordinal; named speakers now require confirmation before re-identification.
8. Kept Transcript schema V1 by making `editedText` optional and added direct legacy-decoding coverage rather than bumping the schema without need.
9. Kept Phase 7 isolated from summaries, LLM processing, waveform, live processing, export and other Phase 8+ work.
10. Added no cloud service and no new runtime dependency; the privacy and dependency boundaries from Phases 5–6 remain unchanged.

Final reviewer pass found no remaining material issue in generated-evidence preservation, edit durability, speaker-name semantics, replacement safety, backward compatibility or inherited capture/transcription/diarization behavior.

## Known partial / physical evidence pending

- **PARTIAL — visual transcript UX:** conversational turn spacing, long-text readability, text selection, editor sheets, search behavior, copy-all and destructive confirmation alerts should be exercised interactively on a real Mac.
- **PARTIAL — timestamp seek feel:** automated code paths compile and existing playback behavior remains green, but human verification should confirm jumping among many transcript turns feels coherent on real recordings.
- **PARTIAL — first-use Whisper model download / real transcription quality:** inherited from Phase 5 and still requires normally signed/sandboxed physical evidence.
- **PARTIAL — first-use SpeakerKit model download / real diarization quality:** inherited from Phase 6 and still requires physical multi-speaker evidence.
- **PARTIAL — long-session resource behavior:** SpeakerKit still requires one full 16 kHz Float buffer; real 1h+ sessions remain memory/thermal/throughput evidence.
- **PARTIAL — physical TCC/system-audio/dual-source capture:** inherited Phase 4+ signed/system-permission smoke debt remains.

These are evidence limitations, not blockers to the automated Phase 7 contract.

## Explicitly out of scope

Phase 7 contains no:

- summaries or LLM processing;
- waveform UI;
- live transcription or live diarization;
- export workflow;
- custom cross-run speaker embedding/cluster identity reconciliation;
- destructive rewriting of Whisper word timing evidence;
- Phase 8+ implementation.

## Next phase

No Phase 8 scope is currently defined in the repository. Phase 8 remains locked until PR #9 is reviewed and explicitly merged, then separately scoped in a subsequent instruction.

Do not implement or merge Phase 8 from this phase branch.
