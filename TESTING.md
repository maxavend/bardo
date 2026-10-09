# Bardo — Manual macOS Smoke Test

This guide validates the current transcription-focused Bardo build on a real Mac.

## Local resources

Bardo uses these private model roots:

```text
~/Library/Application Support/Bardo/Models/
├── whisper-turbo/
└── speaker-kit/
```

Whisper Large v3 Turbo is the transcription engine. SpeakerKit is used only to identify speakers in an existing transcript. Conversation audio and transcript content remain local.

## Smoke test order

### 1. Launch and first-run preparation

- Launch Bardo on a clean install.
- Confirm first-run preparation stays responsive while transcription and speaker resources are prepared.
- After setup succeeds, open Settings → Transcripción and confirm both resources show as ready.
- Quit and reopen Bardo; the Library should appear without replaying first-run setup.

### 1b. Setup without a connection

- On a clean install, turn Wi-Fi off and launch Bardo.
- When setup fails, choose **Continuar sin transcribir** and confirm the Library opens.
- Record or import audio, then reconnect and use **Reintentar** in the banner; transcription becomes available when it finishes.
- In Settings → Transcripción remove the transcription resource, relaunch, and confirm Bardo opens normally with a banner offering **Descargar**.

### 2. Audio import

- Import a short `.m4a`, `.wav`, or other supported audio file.
- Confirm it appears in the Library and can be played and seeked.
- Quit/reopen and confirm the recording persists.

### 3. Microphone recording

- Start a microphone-only recording and grant permission when requested.
- Speak for roughly 15–30 seconds, stop, then play the result.
- Confirm the recording survives an app restart.

### 4. System audio

- Start a system-audio recording.
- Choose a display, app, or window in the macOS sharing picker.
- Grant Screen & System Audio Recording permission if required.
- Confirm the resulting recording plays back.

### 5. System + microphone

- Record system audio and microphone together.
- Confirm Bardo preserves both original sources and produces a playable conversation recording.

### 5b. Interruptions and recovery

- Start a microphone recording, speak for 20 seconds, then force quit Bardo (⌥⌘⎋).
- Relaunch: a banner reports an interrupted recording. Open it, choose **Recuperar**, and confirm the recording appears with its title and plays the 20 seconds.
- Repeat with system + microphone; the recovered recording must contain both sources and the mix.
- During a system-audio recording choose **Cambiar fuente…** and immediately **Finalizar**: the recording must be saved once and the status must not return to "Grabando".
- While choosing content in the macOS picker, use **Cancelar** in Bardo's status pill.
- Quit Bardo with ⌘Q during a recording: it is saved before the app closes.

### 6. Real transcription

- Choose **Transcribe** on a short recording.
- Confirm Whisper resources are downloaded into Bardo's private model root if absent.
- Confirm transcription completes without losing the source audio.
- Confirm timestamped transcript turns appear.
- Click several timestamps and verify playback seeks to the expected audio position.
- Search inside the transcript and copy the full transcript.
- Transcribe a recording of several minutes and confirm the beginning of the conversation is present (an earlier build dropped the opening seconds).
- Start transcribing one conversation, open another, and confirm **Transcribir** explains that Bardo is busy instead of doing nothing.
- Import a file while audio is playing: playback must continue.

### 7. Speaker identification

- Use audio with at least two distinct speakers.
- Choose **Identify Speakers**.
- Confirm SpeakerKit resources are prepared locally if absent.
- Start speaker identification on a long recording and press **Cancelar**: the transcript must become editable again right away.
- Confirm speaker labels are applied to the transcript.
- Name a participant and verify the name updates across their turns.
- Quit/reopen and verify participant names persist.

### 8. Transcript editing and replacement safeguards

- Edit a transcript segment and verify the correction persists after restart.
- Use **Restore Original** and confirm the original recognition text returns.
- With manual corrections present, choose **Transcribe Again** and confirm Bardo warns before replacing the edited transcript.
- With named speakers present, choose **Identify Speakers Again** and confirm Bardo warns before replacing speaker assignments.

### 9. App icon and bundle

- Confirm Bardo shows its custom icon in Finder, the Dock, the app switcher, and the window/app menu context.
- Confirm the icon remains correct after copying the app from a DMG into `/Applications`.

## Visual design review (Debug builds)

Debug builds can drive the real windows into a known state, save each window as a PNG and quit, so a design change can be checked in light and dark, at several window sizes and in every state.

1. Build with a separate bundle identifier (`PRODUCT_BUNDLE_IDENTIFIER=com.maxavend.bardo.design`). `CFFIXED_USER_HOME` isolates Bardo's files but not its preferences, so a separate identifier keeps the review away from your own settings.
2. Seed a sample Library with real transcripts by running `DesignSeedTests` with `TEST_RUNNER_BARDO_DESIGN_SEED_HOME`, `TEST_RUNNER_BARDO_E2E_MODELS_ROOT`, `TEST_RUNNER_BARDO_E2E_AUDIO` and `TEST_RUNNER_BARDO_E2E_LONG_AUDIO`. Copy the models into `<home>/Library/Application Support/Bardo/Models` as real folders (`cp -cR`); Bardo refuses a model folder that resolves through a symbolic link.
3. Launch:

   ```bash
   open -n -W Bardo.app --env CFFIXED_USER_HOME=<home> --args -BardoDesignCapture <folder> -BardoDesignScenario "open:0+inspector" -BardoDesignAppearance dark -BardoDesignWindowSize 980x620
   ```

Steps are joined with `+`: `section:<all|recorded|imported|favorites>`, `open:<index>`, `deselect`, `search:<text>`, `inspector`, `sidebar:hidden`, `speakers`, `rename`, `edit`, `delete`, `seek:<seconds>`, `newRecording`, `settings`, `settingsTab:<general|recording|transcription|storage|privacy>`, `recovery`, `focusList[:index]`, `press:<down|up|space|return|escape|delete|tab>` (real key events), `mute`, `transcribe`, `trash`, `wait:<seconds>` and `menus` (writes every menu item with its shortcut and state). `transcribe` and `trash` change the Library: run them against a copy.

Keep the screen unlocked. A locked screen composites windows as blank sheets; the review then draws the views directly, which shows the layout but not Liquid Glass, vibrancy, sidebars or scrolling content.

## What to report

For any issue, capture what you expected, what happened, whether it reproduces after relaunch, macOS version, Mac model/chip, and a screenshot or screen recording when the problem is visual.
