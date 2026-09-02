# Bardo Local AI Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reliable local Parakeet, WhisperKit model selection, SpeakerKit recovery, text-only Qwen Meeting Minutes, durable speaker/transcript UX, and verifiable Test/Latest DMG distribution to Bardo.

**Architecture:** Evolve the existing `RecordingTranscribing`, `TranscriptionModelManager`, `SpeakerDiarizationService`, `TranscriptStore`, `LibraryViewModel` and setup coordinator. Add one private model-root value/actor, pure recovery/presentation policies, a Parakeet adapter, a Qwen text-only adapter, and shared CI packaging logic. Every production model path is private to Bardo and every model reaches `installed` only after a successful validation/load.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen, XCTest, WhisperKit/SpeakerKit from `argmax-oss-swift` 1.1.0, FluidAudio 0.15.6, MLXSwiftLM 3.31.3, Core ML, `hdiutil`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-01-bardo-local-ai-stabilization-design.md`

## Global Constraints

- macOS deployment target remains 15.0.
- Balanced remains the default: WhisperKit large-v3 Turbo.
- Instant uses Parakeet TDT 0.6B v3 through FluidAudio 0.15.6.
- Maximum Accuracy uses WhisperKit large-v3.
- Meeting Minutes uses `mlx-community/Qwen3.5-0.8B-MLX-4bit` and receives no audio URL or samples.
- Speaker identification remains a post-transcription SpeakerKit/Pyannote operation.
- Private roots are under `~/Library/Application Support/Bardo/Models/`.
- Never read, delete, or mutate global FluidAudio or Hugging Face caches as Bardo ownership.
- Recovery is at most one repair download after a failed load of an already complete private cache.
- First-download network errors and cancellation never trigger destructive repair or a retry.
- Tests use temporary roots and injected adapters; tests never download models or access the network.
- Do not add sleeps, global flags, broad `try?`, or Swift concurrency suppression hacks.
- Do not merge automatically; keep the branch suitable for a Draft PR until all gates pass.

---

### Task 1: Add private model roots and model-state contracts

**Files:**
- Create: `Bardo/Models/BardoModelStore.swift`
- Create: `Bardo/Models/ManagedModelState.swift`
- Modify: `project.yml`
- Test: `BardoTests/BardoModelStoreTests.swift`
- Test: `BardoTests/ManagedModelStateTests.swift`

**Interfaces:**
- `BardoModelStore.live() throws -> BardoModelStore`
- `BardoModelStore(rootURL:fileManager:)`
- `func root(for model: ManagedModel) -> URL`
- `func reset(_ model: ManagedModel) throws`
- `enum ManagedModel: String, CaseIterable, Sendable { case whisperBalanced, whisperMaximumAccuracy, parakeet, speakerKit, qwen }`
- `enum ManagedModelState: Equatable, Sendable { case notInstalled, downloading(Double), preparing(Double), installed, failed(String) }`

- [ ] Write tests proving every model URL is below the injected root, Parakeet does not use a FluidAudio path, and reset only removes the selected child directory.
- [ ] Run `xcodegen generate` and `xcodebuild test -project Bardo.xcodeproj -scheme Bardo -destination 'platform=macOS,arch=arm64' -only-testing:BardoTests/BardoModelStoreTests -only-testing:BardoTests/ManagedModelStateTests CODE_SIGNING_ALLOWED=NO`; confirm the new tests fail because the types do not exist.
- [ ] Implement the root derivation and safe child-directory validation. Reject reset paths that escape the model root.
- [ ] Rerun the focused tests and confirm they pass without touching any user cache.
- [ ] Commit with `git commit -m "feat: add private model ownership boundary"`.

### Task 2: Centralize bounded recovery decisions

**Files:**
- Create: `Bardo/Models/ModelRecoveryPolicy.swift`
- Test: `BardoTests/ModelRecoveryPolicyTests.swift`

**Interfaces:**
- `enum ModelOperationPhase: Equatable, Sendable { case checking, downloading, preparing, loading, inference }`
- `enum ModelRecoveryDecision: Equatable, Sendable { case keepAndSurface, retryLoadAfterRepair, cancelled }`
- `static func decision(wasComplete: Bool, phase: ModelOperationPhase, isCancellation: Bool, errorKind: ModelErrorKind) -> ModelRecoveryDecision`
- `enum ModelErrorKind: Equatable, Sendable { case network, load, other }`

- [ ] Add tests for complete-cache/load-failure → repair, first-download/network-failure → surface, first-download/load-failure → surface, and cancellation in every phase → cancelled.
- [ ] Run the focused policy tests and observe the intended failures before implementation.
- [ ] Implement a pure decision table with no retry loop and no filesystem calls.
- [ ] Run the focused tests and confirm all policy cases pass.
- [ ] Commit with `git commit -m "feat: define bounded model recovery policy"`.

### Task 3: Evolve Whisper model management and selection

**Files:**
- Modify: `Bardo/Transcription/TranscriptionModelManager.swift`
- Modify: `Bardo/Transcription/WhisperTranscriptionService.swift`
- Create: `Bardo/Transcription/TranscriptionBackend.swift`
- Modify: `Bardo/Domain/Transcript.swift`
- Modify: `BardoTests/TranscriptionModelManagerTests.swift`
- Create: `BardoTests/TranscriptionBackendTests.swift`

**Interfaces:**
- `struct TranscriptionModelDefinition: Equatable, Sendable { let id: String; let displayName: String; let requiredFreeBytes: Int64; let isDefault: Bool }`
- `static let catalog: [TranscriptionModelDefinition]`
- `func selectedDefinition() -> TranscriptionModelDefinition`
- `enum TranscriptionBackend: String, Codable, CaseIterable, Sendable { case parakeet, whisperKit }`
- `enum TranscriptionPreset: String, Codable, CaseIterable, Sendable { case instant, balanced, maximumAccuracy }`
- `struct TranscriptionSelection: Equatable, Sendable { let preset: TranscriptionPreset; let backend: TranscriptionBackend; let modelID: String }`

- [ ] Add tests proving the catalog IDs, default Balanced selection, Maximum Accuracy selection, and metadata preservation.
- [ ] Run focused tests and confirm they fail for the missing catalog/selection behavior.
- [ ] Refactor the manager to accept a `TranscriptionModelDefinition`, preserve private Whisper roots, and expose state/progress without changing tokenizer caching semantics.
- [ ] Keep `RecordingTranscribing` source-compatible and add selection-aware metadata to generated transcripts.
- [ ] Run the focused plus existing transcription manager/pipeline tests.
- [ ] Commit with `git commit -m "feat: support selectable transcription backends"`.

### Task 4: Integrate private Parakeet through FluidAudio

**Files:**
- Modify: `project.yml`
- Create: `Bardo/Transcription/ParakeetTranscriptionService.swift`
- Modify: `Bardo/Transcription/TranscriptionBackend.swift`
- Create: `BardoTests/ParakeetModelManagerTests.swift`
- Create: `BardoTests/ParakeetTranscriptNormalizationTests.swift`

**Interfaces:**
- `actor ParakeetModelManager`
- `init(modelRoot: URL, fileManager: FileManager = .default)`
- `func hasInstalledModel() async -> Bool`
- `func prepareForUse(progress:) async throws -> AsrModels`
- `func reset() throws`
- `actor ParakeetTranscriptionService: RecordingTranscribing`

- [ ] Add test seams for download, load and file validation; write tests asserting `AsrModels.download(to:)` and `AsrModels.load(from:)` receive the private Parakeet URL and never the global FluidAudio path.
- [ ] Run focused tests and observe failures because the adapter and manager do not exist.
- [ ] Pin `FluidInference/FluidAudio` to `0.15.6` in `project.yml`, import `FluidAudio` only in the adapter, and use `AsrModels.modelsExist(at:version:.v3,encoderPrecision:.int8)` for completeness.
- [ ] Implement `download → load` separately. On complete-cache/load failure, discard the cached engine, reset only the private Parakeet directory, download once, and load once more. Propagate network errors/cancellation without repair.
- [ ] Use `AsrManager` with the loaded `AsrModels` and normalize ASR output into existing transcript segments/words without feeding Parakeet output into Qwen or SpeakerKit automatically.
- [ ] Run focused normalization/ownership/recovery tests and the full transcription tests.
- [ ] Commit with `git commit -m "feat: isolate and harden Parakeet model storage"`.

### Task 5: Harden SpeakerKit validation and repair

**Files:**
- Modify: `Bardo/Diarization/SpeakerDiarizationService.swift`
- Modify: `BardoTests/SpeakerDiarizationServiceTests.swift`
- Create: `BardoTests/SpeakerModelRecoveryTests.swift`

**Interfaces:**
- `func hasInstalledModels() async -> Bool`
- `func prepareForUse(progress:) async throws`
- `func reset() throws`
- `nonisolated static func recoveryDecision(...) -> ModelRecoveryDecision`

- [ ] Add injected engine/download/load seams and tests for complete cache + load failure, first-download network failure, cancellation, and engine invalidation.
- [ ] Run focused tests and observe expected failures.
- [ ] Keep the existing private SpeakerKit root and replace filename-only readiness with real load validation.
- [ ] Ensure `loadedDiarizer` is cleared before repair; recreate the engine; perform only one repair download/load attempt; preserve valid caches on cancellation/network failure.
- [ ] Update warm-up to remain non-ready after a load failure and return an actionable error/state to its caller.
- [ ] Run all SpeakerKit and diarization integration tests.
- [ ] Commit with `git commit -m "feat: repair corrupted SpeakerKit caches safely"`.

### Task 6: Add text-only Qwen Meeting Minutes and persistence

**Files:**
- Modify: `project.yml`
- Create: `Bardo/MeetingMinutes/MeetingMinutes.swift`
- Create: `Bardo/MeetingMinutes/MeetingMinutesStore.swift`
- Create: `Bardo/MeetingMinutes/QwenMeetingMinutesGenerator.swift`
- Create: `BardoTests/MeetingMinutesStoreTests.swift`
- Create: `BardoTests/MeetingMinutesGeneratorTests.swift`

**Interfaces:**
- `struct MeetingMinutesInput: Equatable, Sendable { let transcript: Transcript; let title: String; let context: String? }`
- `struct MeetingMinutes: Codable, Equatable, Sendable { let recordingID: Recording.ID; let sourceTranscriptMetadata: TranscriptMetadata; let modelID: String; let text: String; let createdAt: Date }`
- `protocol MeetingMinutesGenerating: Sendable { func generate(from input: MeetingMinutesInput, progress:) async throws -> MeetingMinutes }`
- `actor MeetingMinutesStore { func save(_:) throws; func read(recordingID:) throws -> MeetingMinutes?; func delete(recordingID:) throws }`

- [ ] Write save/load/delete round-trip and missing-record tests before implementation.
- [ ] Write generator contract tests with a recording containing audio assets and assert the captured input contains transcript/title/context only and no URL or sample array.
- [ ] Run focused tests and observe expected failures.
- [ ] Pin `ml-explore/mlx-swift-lm` to a compatible exact version, import `MLXLLM`, `MLXLMCommon`, and `HuggingFace` only in the adapter, and configure `HubCache(location: .fixed(directory: qwenRoot))` when the public API permits it.
- [ ] Load `mlx-community/Qwen3.5-0.8B-MLX-4bit` from the private Qwen root, validate local files before `installed`, and expose a documented limitation instead of mutating global cache environment when the API cannot isolate it cleanly.
- [ ] Implement deterministic segment-based chunk extraction plus a deterministic final synthesis prompt that forbids invented names, deadlines, decisions, and agreements.
- [ ] Run store/generator tests and a compile-only test proving Qwen has no audio dependency.
- [ ] Commit with `git commit -m "feat: add text-only meeting minutes generation"`.

### Task 7: Centralize speaker naming and audio preview selection

**Files:**
- Create: `Bardo/Diarization/SpeakerNamingPolicy.swift`
- Create: `Bardo/Diarization/SpeakerPreviewSelector.swift`
- Modify: `Bardo/Features/Library/LibraryViewModel.swift`
- Create: `BardoTests/SpeakerNamingPolicyTests.swift`
- Create: `BardoTests/SpeakerPreviewSelectorTests.swift`

**Interfaces:**
- `enum SpeakerNamingPresentation: Equatable, Sendable { case identifySpeakers; case singleSpeaker; case participants(Int) }`
- `static func presentation(for transcript: Transcript) -> SpeakerNamingPresentation`
- `static func shouldOpenNamingFlow(after transcript: Transcript) -> Bool`
- `struct SpeakerPreview: Equatable, Sendable { let speakerID: Speaker.ID; let startTime: TimeInterval; let endTime: TimeInterval }`
- `static func previews(for transcript: Transcript, maxDuration: TimeInterval = 10) -> [SpeakerPreview]`

- [ ] Add one-speaker/no-prompt and two-plus-speaker/participants tests, plus longest-contiguous-interval and ten-second cap tests.
- [ ] Run focused tests and confirm they fail for the new policies.
- [ ] Implement pure policy/selection utilities from existing segment/word timings; never invent new audio boundaries outside known evidence.
- [ ] Add single-preview playback ownership to the existing playback controller path.
- [ ] Run focused tests and existing transcript UX tests.
- [ ] Commit with `git commit -m "feat: centralize speaker naming and previews"`.

### Task 8: Stabilize persistence and UI task ownership

**Files:**
- Modify: `Bardo/App/TranscriptionSetupCoordinator.swift`
- Modify: `Bardo/App/TranscriptionSetupView.swift`
- Modify: `Bardo/Features/Library/LibraryViewModel.swift`
- Modify: `Bardo/Features/Library/TranscriptContentView.swift`
- Modify: `Bardo/Features/Library/TranscriptEditing.swift`
- Modify: `Bardo/Features/Library/RecordingDetailView.swift`
- Create: `Bardo/Features/Library/MeetingMinutesView.swift`
- Modify: `BardoTests/Phase6IntegrationTests.swift`
- Modify: `BardoTests/TranscriptUXTests.swift`
- Create: `BardoTests/ModelTaskLifecycleTests.swift`

- [ ] Add lifecycle tests proving task references clear after success/failure/cancellation and terminal UI state is not a stale downloading state.
- [ ] Add persistence tests for speaker rename, edit round-trip, original evidence preservation, restore, blank names and rejected blank edits.
- [ ] Run the focused tests and observe the missing lifecycle/presentation behavior.
- [ ] Ensure coordinators own and cancel the real tasks, clear task references in `defer`, and publish `Failed`/idle after errors.
- [ ] Replace repeated speaker-count branching with `SpeakerNamingPolicy`; open naming only after successful diarization with 2+ speakers.
- [ ] Add the naming sheet preview controls and Meeting Minutes action only when a completed transcript exists.
- [ ] Keep `TranscriptSegment.text`, timestamps and `words` unchanged during edits; persist only `editedText` and `Speaker.name` through `TranscriptStore`.
- [ ] Run focused, integration and full UI-model tests.
- [ ] Commit with `git commit -m "feat: stabilize model tasks and transcript UX"`.

### Task 9: Add observable CI and mounted Test/Latest DMG workflows

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/build-test-dmg.yml`
- Create: `.github/workflows/build-latest-dmg.yml`
- Create: `.github/scripts/verify-dmg.sh`
- Modify: `TESTING.md`
- Modify: `README.md`
- Modify: `PROJECT_STATE.md`

- [ ] Add a CI test step writing `xcode-test.log`, printing test case/file/line/assertion summaries on failure, and uploading the visible log artifact.
- [ ] Add a failing shell validation test fixture or local script test proving the DMG verifier rejects an image without `Bardo.app`.
- [ ] Implement shared DMG verification: build Release ARM64, validate app/Info.plist/entitlements, ad-hoc sign, create DMG, attach read-only, assert mounted `Bardo.app` and Applications alias, verify mounted signature/bundle, detach in trap, verify image, write SHA sidecar containing `github.sha`.
- [ ] Make Test and Latest workflows call the same verifier and upload DMG, checksum, mounted-validation log and XCTest log where applicable.
- [ ] Update docs to state exact model roots, recovery behavior, Qwen cache limitation if applicable, ad-hoc/notarization status and physical-only evidence.
- [ ] Run the local equivalent script against the current HEAD and confirm it rejects deliberately invalid images and accepts the generated DMGs.
- [ ] Commit with `git commit -m "ci: verify mounted Test and Latest DMGs"`.

### Task 10: Full final verification and release checkpoint

**Files:**
- Review: `git diff $(git merge-base HEAD main)..HEAD`
- Review: all files changed by Tasks 1–9
- Artifact: `Bardo-Test-<sha>.dmg`, `Bardo-Latest-<sha>.dmg` in temporary output locations

- [ ] Run `git diff --check` and inspect the complete diff against the base commit.
- [ ] Generate Xcode project from `project.yml`.
- [ ] Run a fresh full Debug build and XCTest suite with `xcodebuild`; record exact test count and zero failures.
- [ ] Run a fresh Release ARM64 build and bundle/entitlement/signature validation.
- [ ] Run the complete Test DMG workflow equivalent, including attach/inspect/detach, and record `hdiutil verify` plus checksum.
- [ ] Run the complete Latest DMG workflow equivalent against the same final SHA and record its checksum.
- [ ] Confirm both DMG manifests contain the exact final `git rev-parse HEAD`; do not reuse evidence from a prior commit.
- [ ] Confirm `git status --short` contains only intentionally untracked local artifacts, if any, and no generated project/build files or temporary scripts.
- [ ] Report remote GitHub Actions status separately from local evidence; report physical Mac/TCC/model-quality limitations without claiming them tested.
- [ ] Commit any documentation-only verification updates, then rerun the full verification because the HEAD changed.
