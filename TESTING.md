# Bardo — Manual macOS Smoke Test

This guide validates a Release DMG after the local-AI stabilization changes are built.

The Test and Latest DMGs are ad-hoc signed for development testing. They are not Developer ID signed or notarized, so macOS may require an explicit first-launch approval. CI mounts each image read-only and verifies `Bardo.app`, the `/Applications` alias, bundle metadata and the ad-hoc signature before uploading it.

## Model ownership and recovery

Bardo owns model data only below:

```text
~/Library/Application Support/Bardo/Models/
├── whisper-balanced/
├── whisper-maximum-accuracy/
├── parakeet/
├── speaker-kit/
└── qwen/
```

The global FluidAudio and Hugging Face caches do not make a model Installed and are never removed by Reset. A model operation reports Downloading, Preparing/Optimizing, Installed or Failed. Recovery is limited to one load-triggered repair of the affected Bardo directory; first-download network errors and cancellation do not delete or retry a cache automatically.

Instant uses Parakeet TDT 0.6B v3 through FluidAudio 0.15.6. Balanced uses WhisperKit large-v3 Turbo by default, Maximum Accuracy uses WhisperKit large-v3, SpeakerKit runs after transcription, and Qwen Meeting Minutes receives transcript text only. Qwen never receives the source audio.

## Install

1. Download the `Bardo-Phase7-Test-DMG` artifact from the GitHub Actions run for the testing-build PR.
2. Unzip the Actions artifact and open `Bardo-Phase7-Test.dmg`.
3. Drag `Bardo.app` to `/Applications`.
4. On first launch, if macOS blocks the app because it is not notarized, Control-click `Bardo.app`, choose **Open**, then confirm **Open**.
5. Keep Bardo in `/Applications` for permission testing. Moving or replacing an ad-hoc signed build can cause macOS to ask for permissions again.

## Smoke test order

### 1. Launch and persistence

- Bardo launches without crashing.
- The Library appears.
- Quit and reopen Bardo; the Library remains available.

### 2. Audio import

- Import a short `.m4a`, `.wav`, or other supported audio file.
- Confirm the recording appears in the Library.
- Play it back and seek through the audio.
- Quit/reopen and confirm the imported recording still exists and plays.

### 3. Microphone recording

- Start a microphone-only recording.
- Accept the microphone permission prompt when requested.
- Speak for roughly 15–30 seconds, stop, then play the result.
- Confirm the recording survives an app restart.

### 4. System audio

- Start a system-audio recording.
- Use the native macOS sharing picker to select a display, app, or window that is producing audio.
- Grant Screen & System Audio Recording permission if macOS requests it. If macOS asks Bardo to relaunch after granting permission, quit and reopen it before retrying.
- Confirm the captured recording plays back.

### 5. System + microphone

- Record system audio and microphone together.
- Confirm Bardo preserves both originals and creates/uses the conversation mix for the combined conversation.
- Play the result and check that both sides of the conversation are audible.

### 6. First real transcription

Use a short recording first.

- Choose **Transcribe**.
- Select Instant, Balanced or Maximum Accuracy and confirm the selected private model download/preparation can complete on the network.
- Confirm transcription finishes without losing the source recording.
- Confirm timestamped transcript turns appear.
- Click several transcript timestamps and confirm playback seeks to the expected part of the recording.

### 7. First real speaker identification

Use audio with at least two distinct speakers if possible.

- Choose **Identify Speakers**.
- Confirm SpeakerKit model preparation/download completes.
- Confirm the transcript receives speaker labels.
- Check several turns against the audio; report obvious speaker swaps or long unassigned regions.
- With exactly one detected speaker, confirm the UI shows a non-actionable `1 Speaker` state and does not open naming.
- With two or more speakers, confirm `Participants (N)` opens the naming flow and each speaker has a representative preview of at most 10 seconds.

### 8. Phase 7 transcript UX

- Search for a word that exists in the transcript and confirm matching turns remain discoverable.
- Copy the full transcript and paste it into a text editor.
- Rename one speaker and confirm the name updates across their assigned turns.
- Quit/reopen Bardo and confirm the speaker name persists.
- Edit one transcript segment and confirm the corrected text is shown.
- Quit/reopen and confirm the correction persists.
- Use **Restore Original** and confirm the generated Whisper text returns.

### 9. Replacement safeguards

- Make a manual text correction and/or speaker name.
- Choose **Transcribe Again** and confirm Bardo warns that manual work will be replaced before starting.
- With a named speaker, choose **Identify Speakers Again** and confirm Bardo warns before replacing named speaker clusters.
- Cancel each warning once to confirm cancellation leaves the current transcript unchanged.

### 10. Meeting Minutes

- Generate Meeting Minutes only after transcription has completed.
- Confirm the output uses the transcript and available names/context, not the audio file.
- For a long transcript, confirm chunked extraction completes without invented names, deadlines, decisions or agreements.

## What to report

For any issue, capture:

- which smoke-test section failed;
- what you expected;
- what happened instead;
- whether it reproduces after quitting/reopening Bardo;
- macOS version and Mac model/chip;
- screenshot or screen recording when the problem is visual;
- the recording duration and source type: imported, microphone, system, or system + microphone.

Do not delete a failing Library item before collecting the above evidence unless the failure itself prevents Bardo from launching.

## Known development-build limitations

- This DMG is ad-hoc signed and not notarized for public distribution.
- First real Parakeet/WhisperKit/SpeakerKit downloads and inference, plus Qwen generation, are intentionally manual evidence, not CI evidence.
- The Qwen production adapter uses an explicit private MLX/Hugging Face cache under Bardo. It does not claim ownership from a pre-existing global Hugging Face cache.
- TCC permission behavior is macOS-controlled and may require relaunching the app after granting access.
- Long-recording memory/thermal behavior remains a separate physical test; start with short recordings for this smoke pass.
