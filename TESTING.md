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

- Play something with sound (a video, or a Meet, Zoom or Discord call) and start an **Audio interno** recording. Recording starts at once; there is nothing to choose.
- The first time, macOS asks to let Bardo record system audio; allow it.
- Confirm the resulting recording plays back what was playing.
- Deny or revoke the permission in System Settings › Privacy & Security › Screen & System Audio Recording and record again: Bardo must warn that it heard no Mac audio.

### 5. System + microphone

- Record system audio and microphone together.
- Confirm Bardo preserves both original sources and produces a playable conversation recording.

### 5a. Tracks of a meeting

- Record a call with **Reunión en este Mac**, talking over the other person at least once, then transcribe it.
- With **Ajustes › Transcripción › Transcribir: Cada pista por separado** (the default), your words appear under **Tú** (or the name set in **Tu nombre**) and the call under **Los demás**; overlapping speech keeps both turns.
- Record a call with the Mac's speakers instead of headphones: the microphone's echo of the call must not appear as your words.
- **Identificar participantes** tells apart only the people on the call; **Tú** stays as it is. In the naming sheet, each sample plays only its own track.
- In the player, **Pistas** switches between **Todos**, **Solo yo** and **Solo los demás** and balances the two tracks without losing sync, also after seeking and changing speed.
- **Más acciones › Transcribir de nuevo** offers each track apart or the mix; **Más acciones › Exportar** saves the transcript, the conversation audio, or each track alone.

### 5a1. Live recorder

- Start a **Reunión en este Mac** recording: the detail column shows its title with **Grabando** in red, one line where your voice rises in blue and the Mac's audio falls in orange, a red playhead where audio enters, and below the line **Tu micrófono** and **Audio del Mac**, stacked and centered. Speak, then play a video: each side moves only with its own source.
- **Micrófono del MacBook Air ⌄** lists the Mac's inputs: choose another and keep talking; the recording continues with the new microphone, and the next recording starts with it.
- The red button shows ⏸ and the running time; click it (or Grabación › Pausar, ⌥⌘P) to pause: the time, the line and the playhead stop, **En pausa** replaces **Grabando**, and the button becomes **Reanudar**. Your bars never cross below the line, nor the Mac's above it. Talk and play audio while paused, resume, stop: neither track contains what was said while paused, and both stay in sync.
- Select a conversation during the recording: it opens with the compact recording bar on top; its waveform button returns to the recorder. With Reduce Motion on, the line steps instead of gliding.

- The microphone button at the top (or Grabación › Silenciar micrófono, ⌥⌘S) turns red and **Silenciado** appears by **Tu micrófono**; your side of the line goes flat while the Mac's audio keeps recording. Stop: the microphone track has silence there, not a gap, and stays in sync.

### 5a1b. A saved conversation

- Without a transcript: the recording's waveform (click or drag to jump), the message and a large **Transcribir**, centered.
- The toolbar reads ★ · Compartir · Copiar (with a transcript) · ⓘ · ⋯. Compartir offers the audio, or the transcript and the audio. Copiar puts a structured text on the pasteboard: the title and date, then one block per stretch of speech with who spoke and when (e.g. "Valentina (0:00–1:12)"); a long pause or another speaker starts a new block.

### 5a2. Microphone and output

- In **Nueva grabación**, **Micrófono** and **Salida** list the Mac's devices under **Predeterminado del sistema**. Connect or disconnect a Bluetooth or USB device while the sheet is open: the lists follow.
- Choose the Mac's own microphone while a Bluetooth speaker is the macOS default input and output, and record a call with **Reunión en este Mac**: the microphone track uses the Mac's microphone and the speaker keeps playing in stereo.
- Choose the Bluetooth speaker's microphone: the sheet warns about hands-free mode. Record a minute anyway; both tracks must play at normal speed and last as long as the recording.
- Quit and reopen Bardo: the choices are remembered. Disconnect the chosen device: the sheet shows it as **no conectado** and recordings use the macOS default.

### 5b. Interruptions and recovery

- Start a microphone recording, speak for 20 seconds, then force quit Bardo (⌥⌘⎋).
- Relaunch: a banner reports an interrupted recording. Open it, choose **Recuperar**, and confirm the recording appears with its title and plays the 20 seconds.
- Repeat with system + microphone; the recovered recording must contain both sources and the mix.
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

Steps are joined with `+`: `section:<all|recorded|imported|favorites>`, `open:<index>`, `deselect`, `search:<text>`, `inspector`, `sidebar:hidden`, `speakers`, `rename`, `edit[:<segment>]`, `delete`, `seek:<seconds>`, `play`, `tracks`, `newRecording`, `settings`, `settingsTab:<general|recording|transcription|storage|privacy>`, `recovery`, `focusList[:index]`, `press:<down|up|space|return|escape|delete|tab>` (real key events), `mute[:<volume>]`, `transcribe`, `trash`, `wait:<seconds>` and `menus` (writes every menu item with its shortcut and state). `transcribe` and `trash` change the Library: run them against a copy.

`-BardoDesignScreen sharpest` places the windows on the Retina screen, `-BardoDesignComposite YES` saves each window with its sheets and popovers in one image, `-BardoDesignForceActive YES` draws the front window's controls as focused while you use another app (the sidebar accent still needs Bardo to be frontmost), and `-BardoDesignMicrophone <name>` shows a neutral input device. `tools/portfolio` builds a sample Library with real transcripts and captures every flow with these options.

Keep the screen unlocked. A locked screen composites windows as blank sheets; the review then draws the views directly, which shows the layout but not Liquid Glass, vibrancy, sidebars or scrolling content.

## What to report

For any issue, capture what you expected, what happened, whether it reproduces after relaunch, macOS version, Mac model/chip, and a screenshot or screen recording when the problem is visual.
