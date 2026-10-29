# Changelog

All notable changes to Bardo. Each version is also a [GitHub release](https://github.com/maxavend/bardo/releases) with its DMG.

## 1.1.4 — 2026-10-29

1.1.3 was never released: its build stopped on a compiler time limit, fixed here.

### Library

- **Archive conversations.** Archivar (⌃⌘A) moves conversations out of the Library's lists without deleting them; they wait in the new **Archivadas** section, from where they can come back.
- **Select several at once** with ⌘-click or ⇧-click to archive them or add them to Favoritas together, from the context menu, the toolbar or the new **Conversación** menu.

### Recording

- **Recording in the menu bar.** While Bardo records, a red dot with the time shows in the menu bar, grey while paused. Its menu shows Bardo, pauses, silences the microphone, marks a moment and finishes the recording.

### Transcription

- **Which model and how long.** Información › Detalles técnicos shows the model that transcribed a conversation and how long it took.

## 1.1.2 — 2026-10-29

### Transcription

- **No more words over silence.** Whisper wrote stock phrases such as "Thank you." over silent stretches, once every 22 seconds while a microphone was muted. Text whose audio never rises above room noise is now left out, as it is heard and in the finished transcript.

### Playback

- **Listen to some participants only.** The full player's Opciones lets you choose whom to hear; what the others say is skipped, together with silences if you skip those too.
- **The waveform is ready sooner.** A recording's waveform is read as soon as you choose it, both tracks at once, so the full player opens with it. If it is still being read, placeholder bars stand in and the real ones fade in.

### Design

- The participants button keeps its avatars as close to the edge as to the top, following its curve.

## 1.1.1 — 2026-10-27

### Recording

- **A smoother live waveform.** The recording's waveform glides at the display's full pace, up to 120 Hz on ProMotion screens, instead of stuttering at about 30. It now moves with the screen's clock rather than with each burst of audio, so it never stops and jumps, and each frame takes a fraction of the work it did.

## 1.1.0 — 2026-10-21

### Fixed

- **First launch on a new Mac.** Preparing transcription failed on every Mac that had never run Bardo: the check that protects the models folder rejected the folder before it existed. A fresh install now downloads and prepares everything as expected.

### Transcription

- **Choose how to transcribe.** Settings › Transcripción offers three ways, named for what they mean: **Rápido** (Apple's recognition, built into macOS 26 and later, no download), **Equilibrado** (Whisper Turbo, 646 MB) and **Preciso** (Whisper Large, 3.1 GB, the most accurate and slower). Each shows what it takes and can be downloaded, used, shown in Finder or removed. Speaker identification is the same with any of them.
- **A welcome in two steps.** After what Bardo does, the welcome asks how to transcribe. On macOS 26 and later it suggests Rápido, so a new Mac only downloads the 11 MB speaker models and can transcribe almost at once. Macs set up before keep the Whisper model they already have.
- **Paragraphs of a comfortable length.** Every turn starts a paragraph; short breaths no longer leave lines of five words, and long monologues break at the end of a sentence. Copied and shared text uses the same paragraphs.
- **Play from any word.** Every word of a transcript plays from its moment when clicked, and still selects for copying.

### Recording

- **Choose the microphone and output** a recording uses, in the recording sheet and in Settings › Grabación, with a warning when a Bluetooth headset would drop to call quality.
- **A live recorder.** The recording in progress shows a waveform of the Mac's audio above the line and your microphone below it, a large red pause button with the time, and Finalizar beside it.
- **Pause, resume and mute.** Every recording can pause (⌥⌘P), and the microphone can be silenced without stopping the Mac's audio (⌥⌘S).
- **Moments and sections.** Mark a moment with a title and a note (⌥⌘N) or start a named section (⇧⌥⌘N) while recording or playing; they appear in the waveform and the transcript.
- **Audio quality.** Choose Máxima, Alta, Equilibrada or Compacta and AAC, Apple Lossless or WAV, each with its weight per minute. Every quality stays clear enough to understand and transcribe everything.
- **Compress a recording** from Información to take less space, after a confirmation.
- **Mac audio over Bluetooth headsets** no longer plays back six times too fast.

### Playback

- **Full player.** Open a conversation in the whole window: a close-up waveform that glides under the playhead, coloured by who speaks, with a Liquid Glass line that fills as it plays; moments and sections to edit; and subtitles that scroll like lyrics, with each word lighting up as it is heard.
- **Skip silences** per recording, showing how many pauses and how much time it saves.
- **Smoother and lighter.** Only what is playing redraws, and the waveform follows the display's pace only while playing.

### Participants

- **Merge participants** that were told apart as two, from **Fusionar** on each one, or when two get the same name. Merges can be undone before saving.
- **Coloured avatars** show who took part.

### Design

- Liquid Glass buttons throughout, clearer copy following Apple's writing guidelines, and the app icon shown without its drop shadow.

## 1.0.3 — 2026-10-15

- The app icon is an Icon Composer document, and conversation details open in a sheet.

## 1.0.2 — 2026-10-15

- The toolbar search no longer covers the inspector.

## 1.0.1 — 2026-10-13

- Records the Mac's audio with a Core Audio process tap, and transcribes, plays, identifies and exports a meeting's microphone and Mac audio apart.

## 1.0.0 — 2026-10-09

- First release.
