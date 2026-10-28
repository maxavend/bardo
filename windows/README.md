# Bardo for Windows

A native Windows 11 version of Bardo, built with C# on .NET 10 and WinUI 3. The stack, the macOS-to-Windows mapping and the open technical spikes are in [`docs/windows/STACK.md`](../docs/windows/STACK.md).

## Build and test

Requires the .NET 10 SDK. `Bardo.Core` has no Windows dependencies, so this also works on a Mac.

```bash
dotnet test windows/Bardo.Windows.slnx
```

## Library compatibility

`tests/Bardo.Core.Tests/Fixtures/MacLibrary` is a Library written by the macOS app's own persistence code. After changing `Bardo/Domain` or `Bardo/Persistence`, regenerate it on a Mac and commit the result; CI fails when it is out of date.

```bash
windows/tools/macos-fixtures/make-fixtures.sh
```
