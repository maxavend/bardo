# Bardo Native macOS UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Bardo a finished-feeling native macOS application by exposing expected recording, playback, transcript, minutes, model, navigation, and recovery actions without changing local-first domain contracts.

**Architecture:** Evolve the existing `LibraryViewModel`, `RecordingStore`, `AudioPlaybackController`, and SwiftUI views. Add small, testable action/state adapters where UI needs composition, and add a native Settings scene that reads and commands the existing model services; do not introduce a second persistence or model-management system.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`/`NSPasteboard`, AVFoundation, existing XCTest suite, XcodeGen, macOS Release ARM64 packaging.

**Spec:** `docs/superpowers/specs/2026-09-02-bardo-native-macos-ux-design.md`

## Global Constraints

- Preserve private Bardo ownership for Parakeet, WhisperKit, SpeakerKit, and Qwen model roots.
- Do not read global FluidAudio or Hugging Face caches as proof of installation.
- Preserve imported audio, transcript original evidence, timestamps, words, speaker IDs, meeting-minutes persistence, and bounded recovery behavior.
- Qwen receives transcript text and available speaker names only; it never receives audio.
- Keep the existing visual identity and `NavigationSplitView`; no navigation rewrite.
- Use native macOS controls and SwiftUI APIs; do not port web interaction patterns literally.
- Do not add decorative motion, sleeps, timeout races, global flags, silent `try?` error handling, or unbounded retries.
- New tests must not perform network or model downloads.
- Do not claim CI, Test DMG, or Latest DMG success until the final HEAD has fresh evidence.

---

### Task 1: Establish testable recording-action and title contracts

**Files:**
- Create: `Bardo/Features/Library/RecordingActionPolicy.swift`
- Modify: `Bardo/Persistence/RecordingStore.swift`
- Modify: `Bardo/Features/Library/LibraryViewModel.swift`
- Test: `BardoTests/LibraryViewModelTests.swift`
- Test: `BardoTests/RecordingStoreTests.swift`

**Interfaces:**
- Produces `enum RecordingAction: Equatable, Sendable { case playPause, rename, moveToTrash, revealInFinder, copyManagedLocation }` and a policy that returns actions for a loaded recording.
- Produces `RecordingStore.recordingDirectoryURL(recordingID:) throws -> URL` and `LibraryViewModel.renameRecording(_:to:) async`, `deleteRecording(_:) async`, and `managedLocation(for:) async throws -> URL`.
- Consumes existing `RecordingStore.update`, `RecordingStore.delete`, selection reconciliation, and Bardo-managed library paths.

- [ ] **Step 1: Write failing tests for title validation and managed URL ownership.** Assert that a whitespace-only title is rejected, a valid title is persisted, and the returned recording directory is inside the store root.
- [ ] **Step 2: Run the focused tests and confirm they fail because the action methods and public managed URL are absent.**
- [ ] **Step 3: Implement the minimal store URL accessor and view-model rename/delete methods.** Keep deletion limited to the exact recording directory and clear selection only after successful deletion; preserve audio and manifest semantics for all other recordings.
- [ ] **Step 4: Add `RecordingActionPolicy` and use it as the single source for row/detail action availability.** Make an audio-less recording omit playback while retaining management actions.
- [ ] **Step 5: Run `BardoTests/LibraryViewModelTests.swift` and `BardoTests/RecordingStoreTests.swift` and refactor only after green.**
- [ ] **Step 6: Commit with `feat: add native recording action contracts`.**

### Task 2: Add discoverable library and detail actions

**Files:**
- Modify: `Bardo/Features/Library/LibrarySidebar.swift`
- Modify: `Bardo/Features/Library/LibraryView.swift`
- Modify: `Bardo/Features/Library/RecordingDetailView.swift`
- Modify: `Bardo/Features/Library/RecordingInspector.swift`
- Create: `Bardo/Features/Library/RecordingActionFeedback.swift`
- Test: `BardoTests/LibraryViewModelTests.swift`

**Interfaces:**
- Consumes `RecordingActionPolicy`, `LibraryViewModel` action methods, and `RecordingStore.managedAudioURL`/directory URLs.
- Produces identical context-menu and toolbar labels for Rename, Move to Trash, Reveal in Finder, Copy Location, and Play/Pause, plus a shared transient feedback state.

- [ ] **Step 1: Add failing view-model tests for deleting the selected recording and retaining another selection.**
- [ ] **Step 2: Run the focused tests and verify the failure identifies missing selection/update behavior rather than a test setup error.**
- [ ] **Step 3: Implement row context menus and detail toolbar menus using the policy.** Use `confirmationDialog` for Move to Trash, disable actions while import/transcription/diarization is mutating the selected recording, and use `NSWorkspace.shared.activateFileViewerSelecting` only with a Bardo-managed URL.
- [ ] **Step 4: Implement rename with a focused sheet/text field and explicit rejection of empty/whitespace titles.** Keep error text actionable and preserve the existing title for failed saves.
- [ ] **Step 5: Implement Copy Location through `NSPasteboard` and report “Copied”/failure in `RecordingActionFeedback`.**
- [ ] **Step 6: Add an empty/missing-file state action that reveals the managed directory or retries playback preparation; do not remove the recording automatically.**
- [ ] **Step 7: Build the app target and run the focused tests; commit `feat: expose recording management actions`.**

### Task 3: Make playback self-describing and keyboard-friendly

**Files:**
- Modify: `Bardo/Audio/AudioPlaybackController.swift`
- Modify: `Bardo/Features/Library/LibraryViewModel.swift`
- Modify: `Bardo/Features/Library/FloatingPlaybackBar.swift`
- Modify: `Bardo/Features/Library/RecordingDetailView.swift`
- Test: `BardoTests/AudioPlaybackControllerTests.swift`

**Interfaces:**
- Produces a playback metadata value containing recording title and asset label, exposed read-only by `AudioPlaybackController`.
- Produces stable methods/actions for seek backward/forward and play/pause that keep current URL and selected recording consistent.
- Consumes existing single-player and preview exclusivity behavior.

- [ ] **Step 1: Write failing tests asserting loaded playback metadata is cleared on unload and updated on load.**
- [ ] **Step 2: Run `AudioPlaybackControllerTests` and confirm the metadata assertions fail.**
- [ ] **Step 3: Add the metadata value and set it from `LibraryViewModel.preparePlaybackForSelection` after the managed URL resolves.**
- [ ] **Step 4: Add explicit accessibility labels/help text and native keyboard equivalents for play/pause, 15-second back, and 15-second forward.** Avoid intercepting Space/arrow events while a text editor has focus.
- [ ] **Step 5: Add the current recording/track label and an error action to the floating bar; keep the bar hidden when nothing is loaded.**
- [ ] **Step 6: Run audio tests and a Release compile; commit `feat: clarify playback state and controls`.**

### Task 4: Complete transcript and meeting-minutes action feedback

**Files:**
- Modify: `Bardo/Features/Library/TranscriptContentView.swift`
- Modify: `Bardo/Features/Library/TranscriptEditing.swift`
- Modify: `Bardo/Features/Library/MeetingMinutesView.swift`
- Modify: `Bardo/Features/Library/RecordingDetailView.swift`
- Modify: `Bardo/Features/Library/LibraryViewModel.swift`
- Create: `Bardo/Features/Library/ClipboardFeedback.swift`
- Test: `BardoTests/TranscriptUXTests.swift`
- Test: `BardoTests/Phase6TranscriptPersistenceTests.swift`
- Test: `BardoTests/MeetingMinutesStoreTests.swift`

**Interfaces:**
- Produces copy helpers for transcript and minutes that write only text to `NSPasteboard` and return a user-visible result.
- Consumes existing non-destructive edit/restore methods and `MeetingMinutesStore` persistence.

- [ ] **Step 1: Write failing tests for copying visible edited transcript text, preserving original evidence on restore, and copying generated minutes.**
- [ ] **Step 2: Run the focused tests and confirm failures are caused by missing copy/action behavior.**
- [ ] **Step 3: Implement pure text-building helpers first, using `TranscriptSegment.displayText` and existing minutes text; keep them independent of SwiftUI/AppKit where possible.**
- [ ] **Step 4: Add visible “Edited” treatment and a restore action that calls the existing restore method without rebuilding timestamps/words/original text.**
- [ ] **Step 5: Add Copy Minutes, Regenerate confirmation when minutes already exist, and retry/dismiss actions for errors.**
- [ ] **Step 6: Verify speaker naming remains gated by the existing centralized policy: one speaker never presents the naming sheet, two or more do.**
- [ ] **Step 7: Run transcript/minutes persistence tests and commit `feat: finish transcript and minutes actions`.**

### Task 5: Add native Settings for model lifecycle visibility

**Files:**
- Create: `Bardo/Features/Settings/ModelSettingsViewModel.swift`
- Create: `Bardo/Features/Settings/SettingsView.swift`
- Create: `Bardo/Features/Settings/ModelStatusRow.swift`
- Modify: `Bardo/App/BardoApp.swift`
- Modify: `Bardo/App/TranscriptionSetupCoordinator.swift`
- Modify: `Bardo/Models/ManagedModelState.swift`
- Test: `BardoTests/ManagedModelStateTests.swift`
- Test: `BardoTests/ModelTaskLifecycleTests.swift`
- Test: `BardoTests/TranscriptionModelManagerTests.swift`
- Test: `BardoTests/SpeakerModelRecoveryTests.swift`

**Interfaces:**
- Produces a main-actor `ModelSettingsViewModel` that maps existing manager/service state to rows for Instant/Parakeet, Balanced/Whisper Turbo, Maximum Accuracy/Whisper large-v3, SpeakerKit, and Qwen.
- Produces explicit `install(model:)`, `cancel(model:)`, `retry(model:)`, and `reset(model:)` commands with one owned `Task` per model and terminal-state cleanup.
- Consumes existing `ManagedModelState`, `BardoModelStore`, `TranscriptionModelManager`, `ParakeetTranscriptionService`, `SpeakerDiarizationService`, and Qwen private-root behavior; it must not create a parallel downloader.

- [ ] **Step 1: Write failing state-mapping tests for all five states and for global-cache presence not becoming `installed`.**
- [ ] **Step 2: Run the focused model tests and confirm the missing adapter/state mapping is the failure.**
- [ ] **Step 3: Implement the adapter with injected service protocols or deterministic state providers so unit tests never download models.**
- [ ] **Step 4: Add a `Settings` scene to `BardoApp` and render native rows with status, progress, Cancel, Retry, and Reset confirmation actions.**
- [ ] **Step 5: Connect Settings to the same preparation/cancellation ownership used by onboarding; ensure every success, cancellation, and error path clears its task and displays the terminal state.**
- [ ] **Step 6: Keep onboarding behavior unchanged except for shared lifecycle reporting; do not make Qwen or SpeakerKit on-demand without an existing service contract that supports it safely.**
- [ ] **Step 7: Run all model-recovery tests and compile the Settings scene; commit `feat: add native model settings`.**

### Task 6: Add macOS commands, focus, and accessibility polish

**Files:**
- Modify: `Bardo/App/BardoApp.swift`
- Modify: `Bardo/App/RootView.swift`
- Modify: `Bardo/Features/Library/LibraryView.swift`
- Modify: `Bardo/Features/Library/LibrarySidebar.swift`
- Modify: `Bardo/Features/Library/RecordingDetailView.swift`
- Modify: `Bardo/Features/Library/TranscriptContentView.swift`
- Test: `BardoTests/TranscriptUXTests.swift`
- Test: `BardoTests/LibraryViewModelTests.swift`

**Interfaces:**
- Produces native app commands for Settings, Import Audio, and playback actions where focus can safely route them.
- Consumes the selected recording and existing task state; no new global event bus is allowed.

- [ ] **Step 1: Add deterministic tests for disabled actions during processing and for no-selection empty-state actions.**
- [ ] **Step 2: Run the focused tests and verify the new assertions fail.**
- [ ] **Step 3: Add `CommandGroup` entries and focused actions using SwiftUI `FocusedValues`; guard routing when a text field/editor owns focus.**
- [ ] **Step 4: Add labels/help text for selected recording, progress, failure, cancel, retry, and destructive actions; preserve localized existing copy style.**
- [ ] **Step 5: Check empty, loading, processing, success, failure, and missing-file branches for a next action and ensure all dialogs/sheets support native dismissal.**
- [ ] **Step 6: Run the complete unit suite and commit `feat: polish macOS commands and accessibility`.**

### Task 7: Fresh final verification and DMG evidence

**Files:**
- Inspect and modify only if needed: `.github/workflows/ci.yml`
- Inspect and modify only if needed: `.github/workflows/build-test-dmg.yml`
- Inspect and modify only if needed: `.github/workflows/build-latest-dmg.yml`
- Inspect and modify only if needed: `.github/scripts/test-verify-dmg.sh`
- Inspect and modify only if needed: `.github/scripts/verify-dmg.sh`
- Generated artifacts: `xcode-test.log`, Release app, Test DMG, Latest DMG, SHA sidecars outside tracked source

**Interfaces:**
- Consumes the final source HEAD and existing CI/DMG scripts.
- Produces fresh build/test/bundle/DMG evidence tied to one exact SHA; no previous artifact may be reported for the new implementation.

- [ ] **Step 1: Review the full diff against the base branch and confirm no unrelated source changes or temporary bypasses are tracked.**
- [ ] **Step 2: Generate the Xcode project from the final HEAD and run Release ARM64 build plus XCTest, writing the visible log as `xcode-test.log`.**
- [ ] **Step 3: If tests fail, print the failing test/file/line/assertion summary and fix the source; rerun the complete verification from the new HEAD.**
- [ ] **Step 4: Validate app architecture, bundle identifier, resources, ad-hoc signature, and executable launch metadata.**
- [ ] **Step 5: Build the Test DMG and mount it read-only; verify `Bardo.app` and `/Applications` symlink inside the mounted volume, validate the mounted app signature, run `hdiutil verify`, and detach in a trap-safe cleanup path.**
- [ ] **Step 6: Build the Latest DMG from the same final HEAD, repeat the mounted-volume checks, and write SHA sidecars containing the exact HEAD SHA.**
- [ ] **Step 7: Run the final test suite after any packaging changes, record `git rev-parse HEAD`, `git status --short`, artifact names/checksums, and physical-macOS limitations.**
- [ ] **Step 8: Commit any required CI-only fix with a descriptive message and rerun every affected gate; do not merge automatically or mark a PR ready while a gate is pending.**

## Coverage review

- Recording actions, selection, deletion, rename, Finder, missing files: Tasks 1–2.
- Playback, one-player preview behavior, state, keyboard controls: Task 3.
- Transcript edits, original restoration, copy, minutes, naming policy: Task 4.
- Model states, cancellation, retry, reset, private ownership: Task 5.
- Empty/loading/error feedback, focus, shortcuts, accessibility: Task 6.
- CI observability, final SHA, mounted Test/Latest DMGs, physical limitations: Task 7.
- No task changes model-recovery algorithms, global caches, audio preservation, or Qwen input contracts.
