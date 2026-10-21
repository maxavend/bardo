#!/bin/zsh
# Prepares the homes the portfolio capture uses, next to the seeded `library` home:
#   empty     models only, for the first-run and empty-Library screens
#   recovery  the seeded Library plus a microphone capture interrupted mid-recording
# and the preferences of the isolated `com.maxavend.bardo.portfolio` build.
#
#   tools/portfolio/prepare_homes.sh <homes folder> <interrupted capture.caf>
set -euo pipefail
homes=$1
staged_audio=$2
support="Library/Application Support/Bardo"

rm -rf "$homes/empty" "$homes/recovery"
mkdir -p "$homes/empty/$support"
cp -cR "$homes/library/$support/Models" "$homes/empty/$support/Models"
cp -cR "$homes/library" "$homes/recovery"

capture_id=$(uuidgen)
asset_id=$(uuidgen)
staging="$homes/recovery/$support/.MicrophoneCaptureStaging/$capture_id"
mkdir -p "$staging"
cp "$staged_audio" "$staging/$asset_id.caf"
cat > "$staging/capture.json" <<EOF
{
  "kind" : "microphone",
  "microphoneAssetID" : "$asset_id",
  "recordingID" : "$capture_id",
  "startedAt" : "2026-10-19T12:40:00Z",
  "title" : "Entrevista a Andrés, cuidador"
}
EOF

domain=com.maxavend.bardo.portfolio
defaults delete "$domain" >/dev/null 2>&1 || true
defaults write "$domain" Bardo.WelcomeCompleted.v1 -bool YES
defaults write "$domain" Bardo.Setup.LibraryUnlocked.v1 -bool YES
defaults write "$domain" "Bardo.TranscriptionSetup.v8.large-v3-v20240930_turbo_632MB.pyannote-v3+plda-v4" -bool YES
defaults write "$domain" bardo.favorite-recording-ids -array $(cat "$homes/library/favorites.txt")
echo "Prepared $homes/empty, $homes/recovery and $domain"
