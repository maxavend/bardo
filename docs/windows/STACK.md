# Bardo for Windows: stack

Bardo for Windows is a native Windows 11 app, not a port of the macOS code. It keeps Bardo's product, data format and reliability guarantees, and follows Windows' own design guidelines instead of imitating macOS.

## Principles

- **Native first.** WinUI 3 controls, Fluent materials and Windows behaviour (title bar, keyboard, accessibility, settings patterns). No macOS look-alikes.
- **Same library on both platforms.** `manifest.json` and `transcript.json` keep the schema the macOS app writes, so a Library copied between a Mac and a PC opens on either.
- **Same guarantees.** Private local processing, crash-safe capture, recovery of interrupted recordings, atomic durable writes, a Library that never waits for model setup.
- **Live text stays light.** The rule in `AGENTS.md` applies here too: settled text is plain text, only a newly arrived passage reveals its words once.

## Platform

| Decision | Choice |
|---|---|
| Language and runtime | C# 14 on .NET 10 (LTS) |
| UI framework | WinUI 3, Windows App SDK 2.x |
| Design system | Fluent, as implemented by WinUI 3 and described in the Windows design guidelines |
| App architecture | MVVM; view models live in `Bardo.Core`, so they are tested on any OS |
| Minimum OS | Windows 11 (`10.0.22621.0`); Windows 10 is out of support |
| Architectures | x64 and ARM64 |
| Packaging | MSIX (package identity is needed for Windows AI APIs and clean install/uninstall) |
| Distribution | Microsoft Store, or MSIX signed with Azure Artifact Signing plus App Installer for updates |
| Tests | MSTest |
| CI | GitHub Actions, `windows-latest` and a Windows ARM64 runner |

Rejected: WPF (older visual layer), MAUI/Avalonia/Uno (cross-platform controls, not Windows' own), C++/WinRT (more effort, no benefit here), Swift on Windows (no mature UI story).

## macOS → Windows

| Area | macOS | Windows |
|---|---|---|
| Window | `NavigationSplitView` + inspector, like Mail and Notes | `NavigationView` (left) with list and detail, inspector as a right-hand pane |
| Search | Toolbar `.searchable` | `AutoSuggestBox` in the `TitleBar` control |
| Toolbar, sheets, banners | Toolbar, sheets, inline banners | `CommandBar`, `ContentDialog`, `InfoBar` |
| Settings | Settings scene | Settings page with `SettingsCard` / `SettingsExpander` (Windows Community Toolkit) |
| Icons | SF Symbols | Segoe Fluent Icons |
| Microphone | AVAudioEngine | WASAPI capture (NAudio) |
| System audio | Core Audio process tap, ScreenCaptureKit | WASAPI loopback, whole system or one process (process loopback). No permission prompt |
| Crash-safe capture | Fragmented M4A, CAF linear PCM for the microphone | Media Foundation (built-in AAC encoder, fragmented MP4); WAV staging for the microphone |
| Playback | AVFoundation | `Windows.Media.Playback.MediaPlayer` |
| Waveforms and DSP | Accelerate | `System.Numerics.Tensors` (`TensorPrimitives`) |
| Whisper | WhisperKit on Core ML | Whisper.net (whisper.cpp), same Large v3 / Large v3 Turbo models in GGML; Vulkan on any GPU, CPU fallback |
| Built-in recognition | Apple Speech (macOS 26) | Windows AI speech recognition: public preview, English only for now. Optional engine later |
| Speaker identification | SpeakerKit (pyannote) | sherpa-onnx (pyannote segmentation + speaker embeddings) on ONNX Runtime |
| Accent-insensitive search | `String.folding` | `CompareInfo` with `IgnoreNonSpace \| IgnoreCase` |
| Persistence | JSON, `fsync`, atomic `rename`, `0700`/`0600` | System.Text.Json, `Flush(true)`, atomic `File.Move(overwrite:)`, per-user `%LOCALAPPDATA%\Bardo` |
| Preferences | `UserDefaults` | Packaged app settings (`ApplicationData.LocalSettings`) |
| Logging | OSLog | `Microsoft.Extensions.Logging` |
| Localisation | `.lproj/Localizable.strings` | `.resw` (MRT Core) in the app, `.resx` in `Bardo.Core`; Spanish and English |

## Solution layout

```text
windows/
├── Bardo.Windows.slnx
├── Directory.Build.props        shared settings (nullable, warnings as errors, C# version)
├── src/
│   ├── Bardo.Core/              net10.0, no Windows APIs: domain, persistence, transcript logic
│   ├── Bardo.Audio/             net10.0-windows: capture, encoding, playback, waveforms
│   ├── Bardo.Transcription/     Whisper.net engine and model management
│   ├── Bardo.Diarization/       sherpa-onnx speaker identification
│   └── Bardo.App/               WinUI 3 app, MSIX package
└── tests/
    └── Bardo.Core.Tests/        MSTest; runs on macOS too
```

`Bardo.Core` targets plain `net10.0`, so its tests run on a Mac as well as in Windows CI. It is translated from `Bardo/Domain` and `Bardo/Persistence` together with their tests. `Bardo.Core`, `Bardo.Core.Tests` and a first `Bardo.App` (the Library window, read-only) exist today; the other projects arrive with the spikes below. Until MSIX packaging is set up, the app runs unpackaged and self-contained.

## Compatibility with the macOS Library

The C# serializer matches what Swift's `JSONEncoder` writes:

- dates in transcripts are seconds since 1 January 2001 (Swift's default), not ISO 8601;
- manifests keep `createdAtEpochSeconds` and its exact `createdAtEpochSecondsBitPattern`;
- UUIDs are upper-case, as in `UUID.uuidString`, including folder names;
- absent optionals are omitted, not written as `null`;
- manifest schema versions 1–3 and transcript schema version 1 are read; version 3 is written.

`Bardo.Core.Tests` decodes fixtures produced by the Swift types to keep this true.

## Technical spikes before the UI

1. **Speaker identification with sherpa-onnx from C#.** Its diarization API exists, but a C# example is not confirmed. Compare its turns with SpeakerKit's on the dialogues used by `RealModelEndToEndTests`.
2. **Whisper.net speed.** Vulkan on Intel and AMD integrated GPUs; on ARM64 only the CPU runtime is confirmed, which may be too slow for Large v3.
3. **Microphone plus system audio together**, written crash-safe, and recovered after killing the process mid-recording.

## Design references

- [Design guidelines for Windows apps](https://learn.microsoft.com/windows/apps/design/)
- [Title bar](https://learn.microsoft.com/windows/apps/design/basics/titlebar-design), [Mica](https://learn.microsoft.com/windows/apps/design/style/mica), [Navigation basics](https://learn.microsoft.com/windows/apps/design/basics/navigation-basics)
- [Segoe Fluent Icons](https://learn.microsoft.com/windows/apps/design/style/segoe-fluent-icons-font), [App icon design](https://learn.microsoft.com/windows/apps/design/style/iconography/app-icon-design)
- [Accessibility](https://learn.microsoft.com/windows/apps/design/accessibility/accessibility)
- [Windows Design Kit for Figma and other toolkits](https://learn.microsoft.com/windows/apps/design/downloads/)
- [WinUI 3 Gallery](https://github.com/microsoft/WinUI-Gallery)
- [Writing style](https://learn.microsoft.com/windows/apps/design/style/writing-style) and the [Microsoft Writing Style Guide](https://learn.microsoft.com/style-guide/welcome/)

Fluent 2's site (fluent2.microsoft.design) targets web, iOS, Android and Microsoft 365 apps; for a WinUI app the Windows design guidelines and WinUI Gallery are the reference.
