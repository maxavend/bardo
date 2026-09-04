#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODEL_ID="mlx-community/LFM2.5-1.2B-Instruct-4bit"
MODEL_REVISION="main"
DESTINATION="${BARDO_MINUTES_MODEL_DESTINATION:-$REPO_ROOT/Bardo/Resources/Models/Minutes/LFM2.5-1.2B-Instruct-4bit}"
REPLACE=0

if [ "${1:-}" = "--replace" ]; then
    REPLACE=1
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "usage: $0 [--replace]" >&2
    exit 2
fi

MODEL_ID="$MODEL_ID" MODEL_REVISION="$MODEL_REVISION" DESTINATION="$DESTINATION" REPLACE="$REPLACE" python3 <<'PY'
import json
import os
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

model_id = os.environ["MODEL_ID"]
revision = os.environ["MODEL_REVISION"]
destination = Path(os.environ["DESTINATION"]).expanduser().resolve()
replace = os.environ["REPLACE"] == "1"

if destination.exists() and any(destination.iterdir()) and not replace:
    raise SystemExit(f"destination is not empty; rerun with --replace: {destination}")
destination.parent.mkdir(parents=True, exist_ok=True)

headers = {"User-Agent": "Bardo-local-model-fetcher/1.0"}
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
if token:
    headers["Authorization"] = f"Bearer {token}"

api_url = f"https://huggingface.co/api/models/{model_id}/tree/{revision}?recursive=true&expand=false"
request = urllib.request.Request(api_url, headers=headers)
try:
    with urllib.request.urlopen(request) as response:
        entries = json.load(response)
except urllib.error.HTTPError as error:
    raise SystemExit(f"could not list Hugging Face model files ({error.code}): {error.reason}")

files = sorted(
    entry["path"]
    for entry in entries
    if entry.get("type") == "file" and isinstance(entry.get("path"), str)
)
if not files:
    raise SystemExit(f"Hugging Face model contains no downloadable files: {model_id}@{revision}")

staging = Path(tempfile.mkdtemp(prefix="bardo-minutes-model-", dir=str(destination.parent)))
try:
    for index, relative in enumerate(files, start=1):
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise SystemExit(f"unsafe model path returned by Hugging Face: {relative}")

        output = staging / relative_path
        output.parent.mkdir(parents=True, exist_ok=True)
        encoded_path = urllib.parse.quote(relative, safe="/")
        file_url = f"https://huggingface.co/{model_id}/resolve/{revision}/{encoded_path}?download=true"
        request = urllib.request.Request(file_url, headers=headers)
        print(f"Downloading {index}/{len(files)}: {relative}", flush=True)
        try:
            with urllib.request.urlopen(request) as response, output.open("wb") as stream:
                shutil.copyfileobj(response, stream, length=1024 * 1024)
        except urllib.error.HTTPError as error:
            raise SystemExit(f"could not download {relative} ({error.code}): {error.reason}")

    if destination.exists():
        shutil.rmtree(destination)
    staging.rename(destination)
finally:
    if staging.exists():
        shutil.rmtree(staging)

print(f"Downloaded {model_id}@{revision} to {destination}")
PY
