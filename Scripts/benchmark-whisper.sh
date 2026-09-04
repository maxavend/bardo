#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash Scripts/benchmark-whisper.sh --audio /absolute/path/audio.m4a [options]

Options:
  --reference PATH       Human reference transcript for WER/CER.
  --matrix NAME          workers (default), chunks, long, or single.
  --worker N             Winning worker count required for --matrix chunks.
  --profiles SPEC        Long-form profiles, e.g. 120:2:6,120:2:8.
  --repetitions N        Runs per profile. Defaults to 3; long defaults to 1.
  --cooldown SECONDS     Fixed cooldown between profiles. Default: 5.
  --output DIR           Output directory. Default: ~/Desktop/BardoWhisperBenchmarks/<timestamp>.
  --skip-build           Reuse an existing Release build in .benchmark-derived-data.
  --help                 Show this help.

Single-profile overrides:
  BARDO_WHISPER_WORKERS
  BARDO_WHISPER_CHUNK_SECONDS
  BARDO_WHISPER_BUFFERED_CHUNKS

Examples:
  bash Scripts/benchmark-whisper.sh --audio ~/Desktop/meeting.m4a --matrix workers
  bash Scripts/benchmark-whisper.sh --audio ~/Desktop/meeting.m4a --matrix chunks --worker 6
  bash Scripts/benchmark-whisper.sh --audio ~/Desktop/meeting-60m.m4a --matrix long --profiles 120:2:6,120:2:8 --repetitions 1
EOF
}

AUDIO=""
REFERENCE=""
MATRIX="workers"
WORKER=""
PROFILES=""
REPETITIONS=""
COOLDOWN="5"
OUTPUT=""
SKIP_BUILD="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audio) AUDIO="$2"; shift 2 ;;
    --reference) REFERENCE="$2"; shift 2 ;;
    --matrix) MATRIX="$2"; shift 2 ;;
    --worker) WORKER="$2"; shift 2 ;;
    --profiles) PROFILES="$2"; shift 2 ;;
    --repetitions) REPETITIONS="$2"; shift 2 ;;
    --cooldown) COOLDOWN="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -z "$AUDIO" ]]; then
  echo "--audio is required." >&2
  usage >&2
  exit 64
fi

if [[ ! -f "$AUDIO" ]]; then
  echo "Audio file not found: $AUDIO" >&2
  exit 66
fi

if [[ -n "$REFERENCE" && ! -f "$REFERENCE" ]]; then
  echo "Reference file not found: $REFERENCE" >&2
  exit 66
fi

if [[ "$MATRIX" == "chunks" && -z "$WORKER" ]]; then
  echo "--worker is required for the chunks matrix." >&2
  exit 64
fi

if [[ "$MATRIX" == "long" && -z "$PROFILES" ]]; then
  echo "--profiles is required for the long matrix." >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 69
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$HOME/Desktop/BardoWhisperBenchmarks/$TIMESTAMP-$MATRIX"
fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
AUDIO="$(cd "$(dirname "$AUDIO")" && pwd)/$(basename "$AUDIO")"
if [[ -n "$REFERENCE" ]]; then
  REFERENCE="$(cd "$(dirname "$REFERENCE")" && pwd)/$(basename "$REFERENCE")"
fi

DERIVED_DATA="$ROOT/.benchmark-derived-data"
BINARY="$DERIVED_DATA/Build/Products/Release/Bardo.app/Contents/MacOS/Bardo"

if [[ "$SKIP_BUILD" != "1" || ! -x "$BINARY" ]]; then
  echo "Generating Xcode project..."
  xcodegen generate

  echo "Building Bardo Release..."
  xcodebuild \
    -project Bardo.xcodeproj \
    -scheme Bardo \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build | tee "$OUTPUT/build.log"
fi

if [[ ! -x "$BINARY" ]]; then
  echo "Release binary not found: $BINARY" >&2
  exit 70
fi

export BARDO_WHISPER_DIAGNOSTICS=1
export BARDO_WHISPER_BENCHMARK_AUDIO="$AUDIO"
export BARDO_WHISPER_BENCHMARK_OUTPUT="$OUTPUT"
export BARDO_WHISPER_BENCHMARK_MATRIX="$MATRIX"
export BARDO_WHISPER_BENCHMARK_COOLDOWN_SECONDS="$COOLDOWN"
export BARDO_WHISPER_BENCHMARK_GIT_SHA="$(git rev-parse HEAD 2>/dev/null || true)"

if [[ -n "$REFERENCE" ]]; then
  export BARDO_WHISPER_BENCHMARK_REFERENCE="$REFERENCE"
fi
if [[ -n "$REPETITIONS" ]]; then
  export BARDO_WHISPER_BENCHMARK_REPETITIONS="$REPETITIONS"
fi
if [[ -n "$WORKER" ]]; then
  export BARDO_WHISPER_BENCHMARK_WORKER="$WORKER"
fi
if [[ -n "$PROFILES" ]]; then
  export BARDO_WHISPER_BENCHMARK_LONG_PROFILES="$PROFILES"
fi

echo "Running physical Whisper benchmark..."
echo "Matrix: $MATRIX"
echo "Audio:  $AUDIO"
echo "Output: $OUTPUT"
echo

"$BINARY" 2>&1 | tee "$OUTPUT/benchmark.log"

echo
echo "Done."
echo "JSON:    $OUTPUT/benchmark.json"
echo "Runs:    $OUTPUT/benchmark-runs.csv"
echo "Summary: $OUTPUT/benchmark-summary.csv"
