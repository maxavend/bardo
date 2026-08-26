# Bardo Project State

## Current phase

6 — Diarization

**Status:** PHASE_READY, conditional on the exact documentation head containing this statement passing the same full CI gate. PR #8 must remain draft until that condition is satisfied.

Phases 0–5 are integrated on `main`. Phase 5 was merged through PR #7 with merge commit `8f06724131df77fee7cf9653b62b4ab1b93bc3e4`; `feat/phase-6-diarization` was created exactly from that commit.

The Phase 6 production/reviewer head `8cce00843a336ac7992a399b89b0ccad523fdb88` passed GitHub Actions run `32338124948` (CI #106) with XcodeGen generation, entitlement/configuration checks, Debug build, application bundle verification and **103 XCTest cases with 0 failures**.

## Integrated baseline

- Phase 0 — Foundation: merged and certified.
- Phase 1 — Library & Persistence: merged via PR #2.
- Phase 2 — Audio Import: merged via PR #3.
- Phase 3 — Microphone Recording: merged via PR #4.
- Phase 4 — System Audio: merged and certified.
- Phase 5 — Transcription: merged via PR #7.
- Phase 5 merge / Phase 6 branch base: `8f06724131df77fee7cf9653b62b4ab1b93bc3e4`.
- Phase 6 branch: `feat/phase-6-diarization`.
- Phase 6 PR: #8 — `Phase 6 — Diarization`.
- Platform: macOS 15+, Swift 6, SwiftUI, XcodeGen.
- Recording manifest write schema remains **3**.
- Transcript write schema remains **1**.

## Mission 6.1 — SpeakerKit integration

**Status:** COMPLETE for automated validation; first real model download/inference remains PARTIAL.

- Argmax OSS remains pinned exactly to **1.0.0**.
- Bardo links the `WhisperKit` and `SpeakerKit` products directly.
- Bardo does not link the `ArgmaxOSS` umbrella product or `TTSKit`.
- Diarization uses SpeakerKit's public Pyannote pipeline.
- Production metadata identifies the default pipeline as `pyannote-v3+plda-v4`: Pyannote v3 segmenter/embedder resources plus the v4 PLDA clustering resource used by SpeakerKit 1.0.0.
- SpeakerKit model resources live under `Application Support/Bardo/Models/SpeakerKit/` and are downloaded at runtime rather than bundled in the app.
- The existing sandbox outbound-network entitlement from Phase 5 is reused and remains CI-verified.
- `THIRD_PARTY_NOTICES.md` now covers both direct Argmax products and preserves the complete upstream MIT notice. Runtime-downloaded model artifacts remain separately called out for distribution/licensing review.

### First-use download repair

The adversarial reviewer found a production-only clean-install bug that ordinary compilation could not reveal. The first implementation built `PyannoteConfig(download: false)` and then explicitly called `downloadModels()`. Upstream `PyannoteModelLoader` forwards that flag into model resolution, so a clean Mac with no cached SpeakerKit models would fail with download disabled even though CI compiled successfully.

Production now constructs the public `SpeakerKitDiarizer.pyannote(...)` manager with:

```text
download: true
load: false
```

and owns the lifecycle explicitly:

```text
create manager
→ download/resolve models with progress
→ cancellation check
→ load models
→ cancellation check
→ diarize with progress
→ align speaker intervals to transcript
→ unload models
```

Every thrown/cancelled exit after manager creation also calls `unloadModels()`. Swift 6 exposed two inherited `downloadModels(progressCallback:)` overloads; Bardo resolves the SpeakerKit `@Sendable` contract explicitly instead of weakening concurrency checking.

## Mission 6.2 — Local diarization and audio contract

**Status:** COMPLETE, with long-session resource behavior documented honestly as PARTIAL physical evidence.

Production diarization lives behind the `RecordingDiarizing` boundary and uses the same managed source-selection contract as transcription:

- imported recording → healthy managed imported source;
- microphone-only → managed microphone original;
- system-only → managed system original;
- system + microphone → **requires `conversationMix`**.

A dual recording never silently diarizes only the system original or only the microphone original and presents that as the full conversation. If the combined mix is unavailable, Bardo surfaces a controlled error and preserves all originals/transcript state.

### Memory contract

SpeakerKit 1.0.0's stable public diarization API accepts one complete 16 kHz mono `[Float]` array. Its clustering pipeline is global for one diarization call and resets when a new call begins. There is no public API for reconciling independently clustered chunk speaker IDs.

Therefore Phase 6 deliberately does **not** fake bounded diarization by calling SpeakerKit independently on arbitrary chunks. That could make “speaker 0” in one chunk unrelated to “speaker 0” in the next and would require a second custom embedding-reconciliation system outside the Phase 6 contract.

Approximate raw PCM allocation is:

```text
16,000 Float samples/s × 4 bytes ≈ 64 KB/s
≈ 230 MB for 1 hour
```

plus Core ML models/tensors and normal application memory. Bardo scopes that full-session sample array only to the SpeakerKit inference helper so it can be released before transcript alignment/persistence and does not intentionally create a second full-session copy. Real long-session memory/thermal behavior remains physical `PARTIAL` evidence rather than a false streaming claim.

## Mission 6.3 — Speaker-to-transcript alignment

**Status:** COMPLETE.

SpeakerKit returns timestamped speaker intervals. Bardo does not re-run Whisper and does not rewrite transcript text. `TranscriptSpeakerAligner` applies those intervals to the already durable Phase 5 transcript:

```text
SpeakerKit intervals
+
Phase 5 word timestamps / segment timestamps
↓
overlap scoring
↓
durable Speaker objects + TranscriptSegment.speakerID
```

Alignment rules:

- valid speaker clusters are ordered by first appearance for stable human-facing `Speaker 1`, `Speaker 2`, ... labels;
- word timestamp overlap is used first when available;
- segment overlap is the fallback when words provide no usable overlap;
- gaps with no temporal overlap stay unassigned rather than guessing through silence;
- transcript segment IDs, bounds, words and text are preserved;
- `Transcript.text` remains unchanged by diarization;
- a segment containing more than one real speaker receives the dominant overlap speaker rather than being split/reconstructed.

That last rule is intentional. Phase 6 persists speaker identity on the existing transcript structure; restructuring transcript turns, speaker naming/editing and richer conversation presentation are not smuggled into this phase.

## Mission 6.4 — Durable speaker state

**Status:** COMPLETE.

The existing transcript model already had durable `Speaker` objects and `TranscriptSegment.speakerID`. Phase 6 adds optional `DiarizationMetadata` to the same `transcript.json` document:

- engine;
- engine version;
- model pipeline ID;
- diarization creation date.

Transcript schema remains **V1** because the speaker/speakerID structure already existed and the new metadata field is optional/additive. Automated compatibility verifies that a Phase 5 V1 transcript without `diarizationMetadata` still decodes with `nil` and that new diarization metadata/speaker assignments survive a fresh `TranscriptStore` round trip.

No speaker embeddings, Core ML model paths, model-cache paths or transient SpeakerKit objects are persisted in Domain.

## Mission 6.5 — Failure, cancellation and re-diarization

**Status:** COMPLETE for app-owned state transitions.

Diarization is a refinement of an already valid transcript, not a new Recording processing state. Therefore:

- starting diarization does not mark the Recording as failed/processing;
- success atomically replaces `transcript.json` with the speaker-enriched transcript;
- failure leaves the previously persisted transcript untouched;
- cancellation leaves the previously persisted transcript untouched;
- failed re-diarization preserves previously valid speaker labels;
- a raw Phase 5 transcript remains authoritative if first diarization fails;
- model weights are explicitly unloaded on success, failure and cancellation exits after manager creation;
- transcription and diarization are mutually exclusive in the Library view model.

The existing `TranscriptStore` same-directory temp + atomic rename publication remains the durability boundary. Diarization never mutates managed audio files.

## Mission 6.6 — Minimal speaker UX

**Status:** COMPLETE.

Library transcript detail now provides:

- `Identify Speakers`;
- `Identify Speakers Again` after a successful diarization;
- SpeakerKit model preparation/download progress;
- model-loading, diarizing and saving stages;
- `Cancel Speaker Identification`;
- speaker count;
- speaker engine/version and model-pipeline metadata;
- transcript segments labeled `Speaker 1`, `Speaker 2`, ... in first-appearance order;
- explicit `Unassigned speaker` when no temporal evidence supports an assignment.

The existing transcription UI remains available. Import/reload/transcription controls cannot race diarization work.

No speaker naming/editing UI, transcript-turn restructuring, summary generation, live diarization or waveform work is introduced.

## Integrated automated gate

Phase 6 deterministic tests cover:

```text
existing persisted raw transcript
→ deterministic diarizer boundary
→ timestamped speaker intervals
→ word/segment overlap alignment
→ speakers + speakerID + diarization metadata
→ atomic TranscriptStore save
→ fresh LibraryViewModel / TranscriptStore
→ speaker-enriched transcript reconstructs ✅
```

Additional gates include:

```text
raw transcript text preserved ✅
segment IDs/bounds preserved ✅
speakers ordered by first appearance ✅
word-overlap voting ✅
no-overlap gap remains unassigned ✅
invalid/no speaker activity rejected ✅
Phase 5 transcript without diarization metadata remains readable ✅
new diarization fields round-trip in Transcript schema V1 ✅
diarization failure preserves raw transcript ✅
failed re-diarization preserves prior speaker labels ✅
cancellation publishes no partial speaker state ✅
Recording processing state unaffected by diarization failure/cancel ✅
dual System + Mic still requires conversationMix ✅
all inherited Phase 0–5 regressions ✅
```

## CI evidence

GitHub Actions run `32338124948` (CI #106), production/reviewer head `8cce00843a336ac7992a399b89b0ccad523fdb88`:

- macOS 15.7.7 Apple Silicon runner;
- Xcode 16.4 (16F6);
- Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0;
- exact Argmax OSS package resolution: **1.0.0**;
- explicit Bardo target dependencies: `WhisperKit` + `SpeakerKit`;
- microphone entitlement: passed;
- outbound network client entitlement: passed;
- XcodeGen generation: passed;
- Debug build: **BUILD SUCCEEDED**;
- application bundle/privacy verification: passed;
- XCTest: **TEST SUCCEEDED**;
- **103 tests executed, 0 failures**.

CI intentionally compiles the real SpeakerKit production boundary but does not download the production diarization models or claim real diarization quality/performance.

## Reviewer findings and repairs

The Builder/Reviewer loop materially repaired Phase 6 before certification:

1. Kept the dependency exact at Argmax OSS 1.0.0 and linked only the direct `WhisperKit` + `SpeakerKit` products, not the umbrella/TTS products.
2. Reused the existing durable `Speaker` / `speakerID` structure and kept `DiarizationMetadata` optional so Transcript schema V1 remained backward-compatible instead of bumping schema without need.
3. Made speaker assignment additive over Phase 5 timestamps; raw transcript text and managed audio are never rewritten by diarization.
4. Reused the strict dual-source `conversationMix` requirement rather than allowing silent one-original fallback.
5. Separated diarization lifecycle from Recording processing state so a speaker-identification failure cannot turn a valid transcription/audio Recording into a failed Recording.
6. Added deterministic failure, cancellation, re-diarization and fresh-restart persistence tests.
7. Connected real SpeakerKit download and diarization progress instead of showing synthetic 0→100 jumps.
8. Corrected model provenance metadata from the vague `pyannote-v3` label to `pyannote-v3+plda-v4`.
9. Found the clean-install blocker where `PyannoteConfig(download: false)` made explicit `downloadModels()` unable to download missing models; production now uses `download: true` with an explicitly controlled lifecycle.
10. Fixed the Swift 6 overload ambiguity between SpeakerKitDiarizer and its inherited model-manager `downloadModels(progressCallback:)` without weakening concurrency.
11. Ensured Core ML model unloading occurs on success, failure and cancellation exits after manager creation.
12. Inspected SpeakerKit's global clustering semantics and rejected naive independent chunk diarization because cluster IDs are not safely comparable across separate calls.
13. Scoped the required full-session Float buffer to inference only and documented the real linear-memory contract instead of claiming Phase 5-style bounded behavior.
14. Rechecked the full PR diff: it is based exactly on the integrated Phase 5 merge, is 0 commits behind `main`, and contains no Phase 7 implementation.

Final reviewer pass found no remaining material issue in speaker-label durability, raw-transcript preservation, dual-source selection, failure/cancellation semantics, dependency boundary or Phase 7 leakage.

## Known partial / physical evidence pending

- **PARTIAL — first-use SpeakerKit model download:** actual Pyannote/PLDA model download through a normally signed/sandboxed Bardo build should be smoked on a real Mac.
- **PARTIAL — real diarization quality:** speaker count/assignment should be evaluated on imported, microphone-only, system-only and dual conversation-mix recordings with multiple human speakers.
- **PARTIAL — long-session resource behavior:** SpeakerKit 1.0.0 requires a full 16 kHz Float array; real 1h+ meetings should be observed for memory pressure, thermal behavior and inference throughput.
- **PARTIAL — cancellation during upstream work:** Bardo cooperates with Task cancellation and preserves durable state, but immediate interruption of an already in-flight upstream model transfer or synchronous audio decode is not independently certified.
- **PARTIAL — model-download disk pressure:** Bardo does not invent a hardcoded SpeakerKit model-size threshold; real low-disk model download behavior remains physical evidence and upstream failures are surfaced without touching transcript/audio state.
- Inherited Phase 5 real Whisper model/inference evidence and Phase 4 physical system-audio/dual-capture/TCC smoke debt remain as previously documented.

These are evidence limitations, not blockers to the automated Phase 6 contract.

## Explicitly out of scope

Phase 6 contains no:

- speaker naming or manual speaker editing;
- transcript turn splitting/restructuring for speaker changes;
- summaries or LLM processing;
- live transcription or live diarization;
- waveform work;
- export work;
- Phase 7+ implementation.

## Next phase

After PR #8 is reviewed and explicitly merged in a subsequent instruction, the next permitted phase is:

- **7 — Transcript UX**

Do not implement or merge Phase 7 from this phase branch.
