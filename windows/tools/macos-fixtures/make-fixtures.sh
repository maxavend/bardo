#!/bin/sh
# Rebuilds the Library fixtures that Bardo.Core.Tests reads, using the macOS app's own
# domain and persistence code. Run on a Mac from the repository root.
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
swiftc -O -o "$build/make-fixtures" \
  "$root"/Bardo/Domain/AudioAsset.swift "$root"/Bardo/Domain/AudioSource.swift \
  "$root"/Bardo/Domain/ProcessingState.swift "$root"/Bardo/Domain/Recording.swift \
  "$root"/Bardo/Domain/RecordingNotes.swift "$root"/Bardo/Domain/Transcript.swift \
  "$root"/Bardo/Domain/TranscriptTextSanitizer.swift "$root"/Bardo/Transcription/TranscriptionBackend.swift \
  "$root"/Bardo/Persistence/DurableFile.swift "$root"/Bardo/Persistence/RecordingManifest.swift \
  "$root"/Bardo/Persistence/RecordingStore.swift "$root"/Bardo/Persistence/RecordingStoreIssue.swift \
  "$root"/Bardo/Persistence/TranscriptStore.swift \
  "$root"/windows/tools/macos-fixtures/Stubs.swift "$root"/windows/tools/macos-fixtures/main.swift
"$build/make-fixtures" "$root/windows/tests/Bardo.Core.Tests/Fixtures/MacLibrary"
