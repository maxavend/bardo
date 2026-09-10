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

### 6. Real transcription

- Choose **Transcribe** on a short recording.
- Confirm Whisper resources are downloaded into Bardo's private model root if absent.
- Confirm transcription completes without losing the source audio.
- Confirm timestamped transcript turns appear.
- Click several timestamps and verify playback seeks to the expected audio position.
- Search inside the transcript and copy the full transcript.

### 7. Speaker identification

- Use audio with at least two distinct speakers.
- Choose **Identify Speakers**.
- Confirm SpeakerKit resources are prepared locally if absent.
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

## What to report

For any issue, capture what you expected, what happened, whether it reproduces after relaunch, macOS version, Mac model/chip, and a screenshot or screen recording when the problem is visual.
