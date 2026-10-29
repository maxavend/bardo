# Bardo for Windows

A native Windows 11 version of Bardo, built with C# on .NET 10 and WinUI 3. The stack, the macOS-to-Windows mapping and the open technical spikes are in [`docs/windows/STACK.md`](../docs/windows/STACK.md).

## Build and test

Requires the .NET 10 SDK. `Bardo.Core` has no Windows dependencies, so its tests also run on a Mac.

```bash
dotnet test windows/tests/Bardo.Core.Tests
```

The app itself builds only on Windows. Open `windows/Bardo.Windows.slnx` in Visual Studio and run `Bardo.App`, or:

```bash
dotnet run --project windows/src/Bardo.App -p:Platform=x64
```

Every CI run also publishes a self-contained build and its installer for x64 and ARM64 as workflow artifacts (`Bardo-win-*`, `Bardo-Setup-win-*`). Pushing a `v*` tag attaches `Bardo-<version>-Setup-x64.exe` and `Bardo-<version>-Setup-arm64.exe`, with their `.sha256`, to the release, next to the DMG.

The installer ([`installer/Bardo.iss`](installer/Bardo.iss), Inno Setup 6) installs for the current person under `%LOCALAPPDATA%\Programs\Bardo`, without administrator rights, adds Bardo to Start and to Settings › Apps, and leaves the Library in place when uninstalled. To build one on Windows:

```bash
pwsh windows/installer/build-installer.ps1 -Arch x64
```

It reads the Library in `%LOCALAPPDATA%\Bardo\Library`. To see conversations recorded on a Mac, copy the contents of `~/Library/Application Support/Bardo/Library` there.

## Library compatibility

`tests/Bardo.Core.Tests/Fixtures/MacLibrary` is a Library written by the macOS app's own persistence code. After changing `Bardo/Domain` or `Bardo/Persistence`, regenerate it on a Mac and commit the result; CI fails when it is out of date.

```bash
windows/tools/macos-fixtures/make-fixtures.sh
```
