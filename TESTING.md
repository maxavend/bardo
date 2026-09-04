# Bardo — Manual macOS Smoke Test

This guide validates a Release DMG after the local-AI stabilization changes are built.

The Test and Latest DMGs are ad-hoc signed for development testing. They are not Developer ID signed or notarized, so macOS may require an explicit first-launch approval. CI mounts each image read-only and verifies `Bardo.app`, the `/Applications` alias, bundle metadata and the ad-hoc signature before uploading it.

## Model ownership and recovery

Bardo owns its current runtime models below:

```text
~/Library/Application Support/Bardo/Models/
├── whisper-turbo/
├── speaker-kit/
└── meeting-minutes/
    └── LFM2.5-1.2B-Instruct-4bit/
```

Meeting Minutes is pinned to `mlx-community/LFM2.5-1.2B-Instruct-4bit` revision `125e006d991147f3b432249d1bdf0821987f12b0`. A snapshot must carry the matching `.bardo-model-revision` marker and pass a real MLX load + short local generation health check before Settings shows it as Ready.

Qwen is not used by the current runtime. If an older build left `~/Library/Application Support/Bardo/Models/qwen/`, Settings may show it as legacy storage and offers an explicit removal action. Do not remove it automatically while testing migration behavior.

Whisper Large v3 Turbo is the only transcription engine. SpeakerKit runs on managed conversation audio for diarization. LFM2.5 receives completed transcript text and metadata only; it never receives source audio.

## Install

1. Download the `Bardo-Phase7-Test-DMG` artifact from the GitHub Actions run for the testing-build PR.
2. Unzip the Actions artifact and open `Bardo-Phase7-Test.dmg`.
3. Drag `Bardo.app` to `/Applications`.
4. On first launch, if macOS blocks the app because it is not notarized, Control-click `Bardo.app`, choose **Open**, then confirm **Open**.
5. Keep Bardo in `/Applications` for permission testing. Moving or replacing an ad-hoc signed build can cause macOS to ask for permissions again.

## Smoke test order

### 1. Launch, first-run model verification and persistence

- Bardo launches without crashing.
- On a clean install, confirm first-run progress remains responsive through voice, minutes and participant setup.
- Confirm Meeting Minutes reaches its local loading/checking phase and setup does not complete if the LFM runtime health check fails.
- After setup succeeds, open Settings and confirm Meeting Minutes · LFM2.5 shows Ready.
- Quit and reopen Bardo; the Library should appear directly without replaying first-run setup, and model warm-up should not block the Library.

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
- Confirm Whisper Large v3 Turbo downloads into Bardo’s private model root, validates, and prepares locally.
- Confirm transcription finishes without losing the source recording.
- Confirm timestamped transcript turns appear.
- Click several transcript timestamps and confirm playback seeks to the expected part of the recording.

### 7. First real speaker identification

Use audio with at least two distinct speakers if possible.

- Choose **Identify Speakers**.
- Confirm SpeakerKit downloads into Bardo’s private model root, validates, and prepares locally.
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
- Confirm the first generation uses the already verified local LFM2.5 runtime and does not redownload the model.
- Confirm final Markdown begins streaming during the render stage instead of appearing only at completion.
- Confirm the output uses the transcript and available names/context, not the audio file.
- Confirm Spanish input produces Spanish headings and content.
- Verify questions are not promoted to agreements, people are not assigned tasks unless explicitly responsible, and no absent deadlines/names/decisions are invented.
- For a long transcript, confirm chunked MAP/REDUCE/RENDER processing completes without repetition loops.
- Record time to first rendered token and total generation time on the physical Mac used for certification.

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
- First real WhisperKit/SpeakerKit inference and LFM2.5 Meeting Minutes quality remain physical evidence, not CI quality evidence.
- CI can validate the pinned LFM revision/readiness contract but does not substitute for a real Apple Silicon generation smoke test.
- TCC permission behavior is macOS-controlled and may require relaunching the app after granting access.
- Long-recording memory/thermal behavior remains a separate physical test; start with short recordings for this smoke pass.
