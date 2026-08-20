# Bardo Project State

## Current phase

5 — Transcription

**Status:** PHASE_READY

Phases 0–4 are integrated and certified on `main`. Phase 5 is implemented on `feat/phase-5-transcription` in PR #7 and contains no Phase 6 diarization functionality.

The production/reviewer head `aaae244253ef1f051c5096dee89aa09f4df2edf3` passed GitHub Actions run `32328966302` (CI #96) with XcodeGen generation, entitlement/configuration checks, Debug build, bundle verification and **93 XCTest cases with 0 failures**. Documentation-only commits after that head must pass the same CI before PR #7 is marked ready for review.

## Integrated baseline

- Phase 0 — Foundation: merged and certified.
- Phase 1 — Library & Persistence: merged via PR #2.
- Phase 2 — Audio Import: merged via PR #3.
- Phase 3 — Microphone Recording: merged via PR #4.
- Phase 4 — System Audio: merged and certified before Phase 5 began.
- Phase 5 branch base / current `main` baseline: `df7711173f8592e73c32f290b4a1a7cca868ff0a`.
- Platform: macOS 15+, Swift 6, SwiftUI, XcodeGen.
- Recording manifest write schema remains **3**.

## Mission 5.1 — WhisperKit integration and model resources

**Status:** COMPLETE for automated validation; first real model download/inference smoke remains PARTIAL.

- Argmax OSS is pinned exactly to **1.0.0** in `project.yml`.
- Bardo links only the `WhisperKit` product; `ArgmaxCore` is transitive.
- Bardo does not link the `ArgmaxOSS` umbrella product, `SpeakerKit`, or `TTSKit`.
- Default model: `large-v3-v20240930_626MB`.
- Models live under `Application Support/Bardo/Models/WhisperKit/` rather than in the app bundle or recording domain.
- Existing model folders are accepted only when the required `MelSpectrogram`, `AudioEncoder` and `TextDecoder` Core ML artifacts are present.
- Download is preceded by a free-space preflight; incomplete/invalid folders cannot masquerade as installed models.
- WhisperKit v1.0.0 obtains its tokenizer separately, so Bardo prepares **Core ML model + large-v3 tokenizer** as one resource-readiness step.
- The app sandbox includes `com.apple.security.network.client` for runtime model/tokenizer downloads; CI verifies it alongside the existing microphone entitlement.
- `THIRD_PARTY_NOTICES.md` preserves the upstream MIT notice.

## Mission 5.2 — Bounded transcription pipeline

**Status:** COMPLETE.

Production transcription uses `WhisperTranscriptionService` behind the `RecordingTranscribing` boundary.

Long recordings are planned as bounded overlapping intervals:

```text
source managed audio
→ <= 300 s interval
→ WhisperKit AudioProcessor interval load
→ 16 kHz mono Float samples
→ WhisperKit VAD + word timestamps
→ global transcript timestamps
→ next interval with 1 s overlap
```

Important invariants:

- a full meeting is never intentionally decoded into one in-memory PCM array;
- each planned interval is at most 300 seconds;
- adjacent intervals overlap by one second;
- acceptance boundaries split the overlap so duplicated boundary content is not retained twice;
- non-finite/invalid durations cannot enter an infinite planning loop;
- model resources are loaded with `download: false` after preparation, preventing a hidden second model download during inference;
- WhisperKit models are unloaded after success or failure;
- task cancellation is checked between pipeline stages and chunks and the inference callback cooperates with cancellation.

Automated AVFoundation fixture coverage proves that requesting one second of a four-second stereo 48 kHz file produces approximately one second of 16 kHz mono samples rather than retaining the full source.

## Audio selection contract

- Imported audio: transcribes the healthy managed playback source.
- Microphone-only: transcribes the managed microphone original.
- System-only: transcribes the managed system original.
- System + microphone: **requires the `conversationMix`**.

A dual-source recording never silently falls back to only the system original or only the microphone original and then presents that as the complete conversation. If the mix is unavailable, transcription fails in a controlled/retryable way while originals remain intact.

## Mission 5.3 — Durable transcript

**Status:** COMPLETE.

Transcript persistence is intentionally separate from the recording manifest:

```text
Application Support/Bardo/Library/<recording-uuid>/
├── manifest.json          # Recording schema V3
├── transcript.json        # Transcript schema V1
└── audio/...
```

`transcript.json` persists:

- recording identity;
- detected language when available;
- ordered transcript segments;
- word timestamps/probabilities when provided by WhisperKit;
- engine, engine version and model ID metadata;
- transcript creation date.

Transcript writes use a same-directory temporary file followed by atomic `rename`, so a crash cannot expose a half-written final document. A crash can leave `.transcript-*.tmp`; Bardo detects and preserves that evidence rather than pretending it is a valid transcript.

The recording manifest remains schema V3 because Phase 5 does not add durable recording-manifest fields. Transcript evolution has its own schema boundary, currently V1.

## Mission 5.4 — Retry, cancellation and recovery

**Status:** COMPLETE for app-owned state transitions.

- Starting transcription persists `processing`.
- Successful transcript publication persists `completed`.
- Controlled failure persists `failed` and remains retryable.
- Cancellation returns the recording to `pending` without deleting managed audio.
- Re-transcription failure does not destroy a previously valid `transcript.json`.
- On restart, an abandoned `processing` state is reconciled:
  - valid `transcript.json` → `completed`;
  - missing/corrupt transcript → `failed`, retryable;
  - source audio is preserved.
- Corrupt transcript content never invalidates the recording/audio library entry.

Cancellation of app-owned inference/state work is automated. Immediate network-transfer interruption during a first-time upstream model/tokenizer download is not separately certified by CI and remains a physical/network smoke item rather than a stronger claim.

## Mission 5.5 — Minimal transcript UX

**Status:** COMPLETE.

Library detail now provides:

- `Transcribe`;
- first-use model preparation/download progress;
- model-loading, transcribing and saving stages;
- `Cancel`;
- `Retry Transcription` after failure;
- persisted transcript text with text selection;
- detected language;
- model ID;
- engine/version;
- `Transcribe Again`.

No transcript editing, speaker naming, waveform UI, summary generation or diarization UI is introduced in Phase 5.

## Integrated automated gate

Phase 5 tests cover:

```text
managed recording audio
→ deterministic transcriber boundary
→ transcript creation
→ atomic TranscriptStore publication
→ Recording processing state
→ Library reload
→ delete external/original import source
→ fresh stores / fresh LibraryViewModel
→ Recording + managed audio + transcript reconstruct ✅
```

Additional gates include:

```text
long-duration bounded chunk planning ✅
NaN/+∞/-∞ duration rejection ✅
real AVFoundation bounded interval loading ✅
model installed detection ✅
invalid/unrelated model folder rejection ✅
disk preflight before network setup ✅
tokenizer preparation part of resource readiness ✅
tokenizer failure preserves installed Core ML model ✅
dual capture requires conversationMix ✅
transcript schema V1 read/write ✅
identity mismatch / corrupt transcript rejection ✅
atomic overwrite preserves prior valid transcript semantics ✅
interrupted processing restart recovery ✅
residual transcript temp detection ✅
retry/re-transcription preserves prior transcript on failure ✅
all inherited Phase 0–4 regressions ✅
```

## CI evidence

GitHub Actions run `32328966302` (CI #96), production/reviewer head `aaae244253ef1f051c5096dee89aa09f4df2edf3`:

- macOS 15.7.7 Apple Silicon runner;
- Xcode 16.4 (16F6);
- Swift 6.1.2 targeting `arm64-apple-macosx15.0`;
- XcodeGen 2.46.0;
- exact Argmax OSS package resolution: **1.0.0**;
- microphone entitlement: passed;
- outbound network client entitlement: passed;
- XcodeGen generation: passed;
- Debug build: **BUILD SUCCEEDED**;
- application bundle/privacy verification: passed;
- XCTest: **TEST SUCCEEDED**;
- **93 tests executed, 0 failures**.

CI deliberately does not download the 600+ MB production model or claim real Neural Engine performance; model acquisition is exercised through injected deterministic test preparation and actual package compilation.

## Reviewer findings and repairs

The Builder/Reviewer loop materially repaired Phase 5 before certification:

1. Kept Phase 5 isolated from SpeakerKit/Phase 6 and pinned WhisperKit exactly instead of using a floating dependency.
2. Repaired Swift 6.1 rejection of `Self` in default arguments.
3. Kept strict concurrency enabled; used `@preconcurrency` compatibility at the WhisperKit boundary rather than weakening compiler settings for its non-Sendable class.
4. Prevented `+∞`, `NaN` and invalid chunk parameters from producing runaway planning.
5. Tightened installed-model verification so unrelated `.mlpackage` folders cannot masquerade as Whisper resources.
6. Reconciled abandoned `processing` recordings after restart.
7. Preserved an existing valid transcript when a re-transcription attempt fails.
8. Prevented dual System + Mic recordings from silently transcribing only one original when the conversation mix is missing.
9. Found that WhisperKit v1.0.0 prepares the tokenizer separately and moved tokenizer preparation into first-use resource setup.
10. Fixed Swift 6 XCTest actor/autoclosure diagnostics without weakening isolation.
11. Added the missing sandbox outbound-network entitlement required for model downloads and made CI assert it.
12. Completed the upstream MIT notice instead of merely naming the license.

Final reviewer pass found no remaining material issue in transcript durability, bounded memory design, audio selection, recovery semantics, Phase 6 leakage, or inherited recording behavior.

## Known partial / physical evidence pending

- **PARTIAL — first-use production model download:** actual large-v3 Core ML + tokenizer download through the signed/sandboxed app should be smoked on a real Mac.
- **PARTIAL — real Whisper inference:** human listening/transcript-quality smoke on imported, microphone, system-only and dual conversation-mix recordings remains physical evidence.
- **PARTIAL — performance:** long real meetings should be observed for memory pressure, thermal behavior and Apple Silicon/Neural Engine throughput; CI proves bounded input planning, not end-user speed.
- **PARTIAL — cancellation during an in-flight first download:** app task cancellation is implemented, but immediate upstream network-transfer interruption is not independently certified.
- Inherited Phase 4 physical system-audio/dual-capture and normally signed TCC smoke debt remains as documented before Phase 5.

These are evidence limitations, not blockers to the automated Phase 5 contract.

## Explicitly out of scope

Phase 5 contains no:

- SpeakerKit integration;
- speaker diarization or speaker assignment;
- speaker naming;
- summaries/LLM processing;
- live transcription;
- transcript editing;
- waveform work;
- Phase 6+ implementation.

## Next phase

After PR #7 is reviewed and explicitly merged in a subsequent instruction, the next permitted phase is:

- **6 — Diarization**

Do not implement or merge Phase 6 from this phase branch.
