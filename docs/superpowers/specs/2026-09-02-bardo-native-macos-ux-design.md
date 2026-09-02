# Bardo Native macOS UX Design

## Goal

Make Bardo feel complete and predictable for daily macOS use by exposing the actions users reasonably expect, improving state and error feedback, and preserving the existing local-first model, audio, persistence, recovery, diarization, and non-destructive transcript-editing contracts.

## Current architecture and constraints

- `BardoApp` owns the single macOS window and currently presents `BardoLaunchView`, which gates access to `RootView` until the existing transcription and SpeakerKit setup is ready.
- `RootView` owns recording controllers and the library flow; `LibraryView` owns the split navigation and `LibraryViewModel` owns selection, persistence, playback preparation, transcription, diarization, and meeting-minutes tasks.
- `RecordingStore` is the source of truth for managed recordings and copies imported audio into Bardo-owned application-support storage. Existing recordings and audio must remain preserved on failures.
- `TranscriptStore`, `MeetingMinutesStore`, the transcription managers, `SpeakerDiarizationService`, and `QwenMeetingMinutesGenerator` remain the existing sources of truth for their domains.
- New UI must use native SwiftUI/AppKit behaviors: `List` selection, `Menu`, `contextMenu`, `confirmationDialog`, `Settings`, `NSWorkspace`, `FocusedValues`, and accessibility labels where appropriate.
- Qwen remains text-only and model ownership remains private to Bardo. No global cache mutation, cloud fallback, network call in tests, or destructive cache cleanup is introduced.
- No visual identity rewrite is planned. New motion is not required; existing progress messaging remains static or uses only the current reduced-motion-aware behavior.

## User-visible behavior

### Library and recordings

Single-click selects a recording and updates the detail view and playback preparation. A recording row and the detail toolbar expose the same secondary actions: play/pause, rename, Move to Trash, Reveal in Finder, and copy the managed recording location. Delete requires a native confirmation and updates selection safely after persistence succeeds. Missing managed audio remains visible as an actionable issue rather than silently disappearing.

Rename uses a focused native text field, rejects whitespace-only titles, persists through `RecordingStore.update`, and reports success or failure in the same surface that initiated the action. The row context menu and detail toolbar use identical labels and action ordering.

### Playback

The floating playback bar identifies the selected recording and the loaded track. Its controls have explicit accessibility labels and keyboard equivalents for play/pause, seeking backward, and seeking forward. Selection changes unload the previous asset before loading the next one, and stale async preparation cannot overwrite the current selection. Missing-file errors offer a direct route to the managed location.

### Transcript and minutes

Transcript actions remain non-destructive. The UI makes Copy Transcript, Edit, Restore Original, Play From Here, and speaker actions discoverable without changing the existing data model. Edited segments visibly identify that they differ from original recognition text; restoring removes only the edit. Meeting minutes expose Copy Minutes, Generate, Regenerate, progress, and an actionable retry state. Copy actions provide short native feedback and never include audio in the Qwen input.

### Settings and model status

The app gains a native Settings scene that composes existing model services rather than replacing them. Each model row reports `Not Installed`, `Downloading`, `Preparing`, `Installed`, or `Failed`, with the available action (`Install`, `Cancel`, `Retry`, or `Reset`). Installed means the corresponding private Bardo-owned installation is valid according to the existing manager/service validation, never merely that a global cache contains files.

Settings does not change the current launch gate or automatically alter when SpeakerKit/Qwen are downloaded. It gives the user a discoverable place to inspect and repair the existing lifecycle. Reset delegates to the existing private model store and never touches FluidAudio or Hugging Face global locations.

### macOS interaction and accessibility

The app adds application commands for opening Settings, importing audio, and focusing the library where the current scene can safely handle them. Escape closes transient sheets/dialogs through native presentation behavior. Buttons, progress indicators, menus, selected rows, empty states, and errors receive labels/help text appropriate to macOS VoiceOver and keyboard navigation. Actions are not duplicated as decorative controls; every new affordance must have a clear user task behind it.

## Data and recovery invariants

- Recording deletion targets only the selected Bardo-managed recording directory after confirmation.
- Reveal-in-Finder resolves only Bardo-managed URLs returned by `RecordingStore`; it never reveals or modifies external/global model caches.
- Recording title edits persist in the manifest and do not touch audio bytes, transcript contents, or model roots.
- Transcript edits preserve original text, words, timestamps, and recognition evidence.
- Model operations keep the current bounded download/load/repair policy. UX changes must not add retries, sleeps, timeout races, or background warm-up states that claim readiness without a successful load.
- Every long-running task remains owned by its view model/service until completion or explicit cancellation, and all terminal paths clear loading state.

## Verification strategy

- Add deterministic unit tests for title validation, recording action targeting, selection after deletion, playback metadata, and settings state mapping.
- Preserve and run all existing persistence, model-recovery, diarization, transcript-editing, and meeting-minutes tests.
- Build the Release ARM64 app, run XCTest with a visible `xcode-test.log`, validate the app bundle/signature, create and mount both Test and Latest DMGs, verify `Bardo.app` inside each mounted volume, and record the exact HEAD SHA used for each artifact.
- Physical validation still required on a real macOS desktop: VoiceOver focus order, Finder/Trash presentation, keyboard event routing while editing text, and actual audio/model behavior with user-owned files.
