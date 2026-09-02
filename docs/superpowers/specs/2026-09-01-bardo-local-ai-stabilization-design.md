# Bardo Local AI Stabilization Design

## Context and scope

Bardo currently has a working local WhisperKit transcription path, a SpeakerKit diarization path, durable transcript edits and speaker names, and a SwiftUI onboarding flow. It does not yet contain Parakeet/FluidAudio, Qwen Meeting Minutes, a central model-state contract, or a mounted-DMG verification workflow. This design extends those existing boundaries without replacing them.

The result is a macOS 15+ local-first application with four selectable capabilities:

- Instant: Parakeet TDT 0.6B v3 through FluidAudio 0.15.6.
- Balanced: WhisperKit large-v3 Turbo, the default.
- Maximum Accuracy: WhisperKit large-v3.
- Meeting Minutes: Qwen 3.5 0.8B MLX 4-bit, receiving only a completed transcript and context.

Speaker identification remains a post-transcription operation through SpeakerKit/Pyannote.

## Design decisions

### 1. One ownership boundary for all model paths

Add a small `BardoModelStore` value/actor that derives all application-owned roots from Application Support:

```text
~/Library/Application Support/Bardo/Models/
├── WhisperKit/<model-id>/
├── Parakeet/parakeet-tdt-0.6b-v3/
├── SpeakerKit/
└── Qwen/<safe-model-id>/
```

The store exposes validated, model-specific URLs and safe deletion methods. It never discovers, imports, deletes, or treats as owned any global FluidAudio or Hugging Face cache. Tests inject a temporary root and can assert that unrelated roots are untouched.

Every model manager reports a shared state enum:

```swift
enum ManagedModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case preparing(Double)
    case installed
    case failed(String)
}
```

The state is derived from the active operation and a successful validation/load, not from a UserDefaults completion bit or the presence of a few filenames. UserDefaults may remember the last selected model, but it cannot make a model `installed`.

### 2. Explicit download → load → bounded repair

Each manager uses the same recovery shape:

1. Inspect only its private directory.
2. If the private directory is complete, load it without a download.
3. If load fails for a previously installed cache, invalidate the in-memory engine, remove only that private model directory, download once, and load once more.
4. If the first download fails, surface the original error and do not perform destructive repair or a second full download.
5. If cancellation is observed, propagate cancellation, retain valid files, and do not repair or retry.

The recovery decision is represented by a pure policy function and receives `wasInstalled`, `operationPhase`, `error`, and `isCancelled`. It has no loops and no sleeps. Download callbacks update progress; task ownership is retained by the coordinator/view model, and cancellation calls the actual task's `cancel()`.

### 3. Parakeet adapter

Add `ParakeetTranscriptionService` conforming to the existing `RecordingTranscribing` protocol. It uses the official FluidAudio 0.15.6 APIs:

- `AsrModels.modelsExist(at:version:encoderPrecision:)` for file completeness;
- `AsrModels.download(to:version:encoderPrecision:progressHandler:)` into Bardo's private Parakeet directory;
- `AsrModels.load(from:configuration:version:encoderPrecision:progressHandler:)` from that same directory;
- `AsrManager(config:models:)`/`loadModels(_:)` for inference.

`downloadAndLoad` is deliberately not used because it collapses the failure phases and makes it impossible to distinguish a network failure from a corrupt installed cache. `AsrManager` is actor-isolated and is cached only after successful model loading. Parakeet results are normalized into the existing `Transcript`, `TranscriptSegment`, `TranscriptWord` and `TranscriptMetadata` types. Parakeet is selected through a model/backend selection abstraction; WhisperKit remains the default Balanced backend.

### 4. WhisperKit model selection

Evolve `TranscriptionModelManager` to support the two existing Whisper variants through a model catalog instead of a single hard-coded ID. Preserve its current tokenizer preparation and private `WhisperKit` root. Each catalog entry carries display name, model ID, required disk space and default flag. The selected backend is stored in the existing recording/transcription flow, and `TranscriptMetadata` records the actual engine/model used.

### 5. SpeakerKit validity and repair

Keep `SpeakerDiarizationService` and its private root. Replace filename-only `hasInstalledModels()` with a two-level check:

- cheap completeness check for `Not Installed`/download progress;
- real load validation before publishing `Installed` or `Ready`.

On a load failure from a complete private cache, set `loadedDiarizer = nil`, remove only the private SpeakerKit directory, recreate the engine, download once, and load once. First-download network failure and cancellation never delete or repair. Warm-up runs through the same validation path and may only publish readiness after a successful load; a background error leaves the setup state actionable.

The existing `RecordingDiarizing` contract remains unchanged for consumers. A small `SpeakerModelRecoveryPolicy` is pure and directly tested.

### 6. Meeting Minutes as a downstream text-only capability

Add `MeetingMinutes` and `MeetingMinutesStore` under the existing persistence boundary. A meeting-minutes record is keyed by recording ID and stores source transcript identity/metadata, generated markdown/text, creation date and model ID. It supports atomic save/load/delete with explicit not-found and identity errors.

Add a `MeetingMinutesGenerating` protocol. Its production implementation loads Qwen through MLXSwiftLM's `LLMModelFactory` and `ModelContainer`, using `HubCache(location: .fixed(directory: ...))` and the private Qwen directory when the pinned library exposes that path cleanly. If the exact library version cannot provide a private cache without process-global hacks, the manager will use a local resolved directory and report the limitation in documentation; UI will not infer ownership from the global cache.

The generator accepts a `MeetingMinutesInput` containing only:

- completed transcript text/segments;
- available speaker names and labels;
- title and minimal context.

It has no audio URL parameter. Long transcripts use deterministic extraction/chunking already represented by transcript segments, followed by a deterministic synthesis pass. Generation parameters use greedy/temperature-zero behavior where supported. The prompt explicitly forbids invented names, deadlines, decisions and agreements; questions remain questions unless the transcript states an answer or decision.

### 7. Speaker naming policy and previews

Add one reusable `SpeakerNamingPolicy`:

- zero speakers → `.identifySpeakers`;
- one speaker → `.singleSpeaker` and no naming sheet;
- two or more → `.showParticipants(count)` and naming allowed;
- successful diarization with two or more speakers → `.openNamingFlow`.

Views and view models consume this policy rather than repeating count checks. Add a `SpeakerPreviewSelecting` pure utility that chooses the longest continuous representative audio interval for each speaker, capped at 10 seconds. The playback controller receives one preview at a time; starting another stops the previous preview. The naming sheet lists detected speakers, exposes playback for each sample and persists names through the existing transcript store. Blank/whitespace names become `nil`.

### 8. Durable transcript invariants

Keep `TranscriptSegment.text` and `words` as generated evidence and `editedText` as the only manual overlay. `displayText` remains the presentation value. Restore removes only `editedText`. Existing `TranscriptStore` atomic publication is reused and covered by fresh-process/ViewModel round trips.

Speaker names use the existing durable `Speaker.name` field. Re-diarization continues to create new speaker identities and must not carry names by ordinal. The naming flow is never opened for a one-speaker transcript.

### 9. UI operation lifecycle

`TranscriptionSetupCoordinator` and `LibraryViewModel` retain the actual download/inference tasks, clear them in `defer`, and publish terminal `installed`, `failed` or idle state after completion. A failure never leaves a progress enum active. Buttons expose `Cancel`, `Retry`, and `Reset & Download Again` only when the operation/state allows them. No timeout task is introduced around a non-cooperative child task.

The Settings/onboarding copy maps the shared model state to `Downloading`, `Preparing / Optimizing for Mac`, `Installed` and `Failed`, with actionable error text. A successful setup requires all selected mandatory capabilities to have passed their real load validation.

### 10. CI and distribution verification

Keep `Build Test DMG` and add/update `Build Latest DMG`; both use the checked-out workflow SHA and generate the Xcode project from `project.yml`. CI uses `xcode-test.log`, prints a filtered XCTest summary on failure, uploads the log with hidden-file exclusion avoided, and retains test name/file/line/assertion output.

Both DMG workflows share a shell step or equivalent action that:

1. builds Release ARM64;
2. validates `Bardo.app`, Info.plist and entitlements;
3. signs ad-hoc with hardened runtime;
4. creates the DMG;
5. mounts it read-only with `hdiutil attach`;
6. asserts the mounted volume contains `Bardo.app` and `/Applications` alias;
7. validates the mounted app bundle and signature;
8. detaches the volume in a cleanup trap;
9. verifies the DMG and writes a SHA-256 sidecar;
10. uploads the DMG, sidecar, and relevant logs.

The Latest artifact includes the exact `github.sha` in its artifact metadata or sidecar. The local equivalent is run against the final HEAD; remote GitHub Actions results are reported separately and never mixed with another commit's evidence.

## Implementation sequence and gates

The implementation is split into four checkpoints:

1. Model ownership and recovery: model paths, state, Parakeet, Whisper catalog, SpeakerKit recovery and focused policy tests.
2. Inference pipeline: backend selection, Parakeet transcript normalization, Qwen text-only generation/storage and long-transcript handling.
3. Durability and UI: speaker policy, audio previews, task lifecycle, setup/settings states and persistence regressions.
4. CI/DMG and documentation: observable XCTest logs, mounted image verification, dual workflows, README/PROJECT_STATE/TESTING updates.

Each checkpoint follows test-first red/green/refactor, runs the focused XCTest target before moving on, and ends with a descriptive commit. No production code is added without a regression test that first demonstrated the missing behavior.

## Non-goals and limitations

- No cloud ASR, diarization or summarization service.
- No deletion or mutation of `~/Library/Application Support/FluidAudio` or the global Hugging Face cache.
- No process-global environment-variable mutation for cache routing.
- No automatic quality claims for real model inference in CI; CI compiles and validates boundaries, while first-use downloads and audio quality remain physical Mac evidence.
- No automatic merge to `main`.
- If MLXSwiftLM's public API cannot cleanly pin Qwen's cache to the private root, the limitation is documented and the UI reports only validated local ownership.

## Acceptance criteria

The final HEAD is accepted only when the focused and full XCTest suites pass with zero failures, Swift 6 async assertions compile without synchronous autoclosure misuse, both workflows contain mounted-DMG checks, local Test/Latest-equivalent DMGs verify successfully, and every reported artifact/checksum maps to the same final HEAD. Any unavailable remote GitHub Actions run or physical-only behavior is explicitly reported rather than inferred.
