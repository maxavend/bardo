#!/usr/bin/env python3
"""Synthesizes the portfolio conversations with macOS voices.

    python3 -I tools/portfolio/generate_audio.py <conversations.json> <output folder>

For each conversation it writes the audio Bardo would have captured or imported:

- meeting:    microphone.m4a (your turns), system.m4a (everyone else) and mix.m4a
- microphone: microphone.m4a
- system:     system.m4a
- imported:   the file name given in the script

plus `timeline.json` with every turn's persona, text and time, which the seed uses to
name the speakers SpeakerKit finds. Needs `say`, `ffmpeg` and `ffprobe`.
"""
import array
import json
import random
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 48_000


def synthesize(text: str, voice: str, rate: int, work: Path, index: int) -> array.array:
    aiff = work / f"turn-{index:03d}.aiff"
    raw = work / f"turn-{index:03d}.raw"
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(aiff), "-ac", "1", "-ar", str(RATE),
         "-af", "volume=0.9", "-f", "s16le", str(raw)],
        check=True,
    )
    samples = array.array("h")
    samples.frombytes(raw.read_bytes())
    return samples


def room_tone(length: int, seed: int, level: int) -> array.array:
    """A quiet noise floor, so tracks sound recorded rather than digitally silent."""
    generator = random.Random(seed)
    return array.array("h", (int(generator.gauss(0, level)) for _ in range(length)))


def mix_into(target: array.array, source: array.array, offset: int) -> None:
    end = offset + len(source)
    if len(target) < end:
        target.extend([0] * (end - len(target)))
    for i, value in enumerate(source):
        total = target[offset + i] + value
        target[offset + i] = max(-32768, min(32767, total))


def write_m4a(samples: array.array, url: Path, work: Path) -> None:
    wav = work / (url.stem + ".wav")
    with wave.open(str(wav), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(samples.tobytes())
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "aac", "-b:a", "128k", str(url)],
        check=True,
    )


def main() -> None:
    script = json.loads(Path(sys.argv[1]).read_text())
    output = Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    cast = script["cast"]

    for number, conversation in enumerate(script["conversations"]):
        folder = output / conversation["id"]
        folder.mkdir(exist_ok=True)
        generator = random.Random(number)
        timeline = []
        microphone = array.array("h")
        system = array.array("h")
        cursor = int(0.8 * RATE)

        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            for index, (persona, text) in enumerate(conversation["turns"]):
                voice = cast[persona]
                samples = synthesize(text, voice["voice"], voice["rate"], work, index)
                track = microphone if persona == "tu" or conversation["kind"] == "microphone" else system
                mix_into(track, samples, cursor)
                start = cursor / RATE
                end = (cursor + len(samples)) / RATE
                timeline.append({"persona": persona, "text": text, "start": round(start, 3), "end": round(end, 3)})
                # Natural turn-taking: short, varied pauses between speakers.
                cursor += len(samples) + int(generator.uniform(0.35, 0.8) * RATE)
                print(f"  {conversation['id']} {index + 1}/{len(conversation['turns'])} {persona}", flush=True)

            length = cursor + int(0.6 * RATE)
            for track in (microphone, system):
                track.extend([0] * (length - len(track)))

            kind = conversation["kind"]
            if kind in ("meeting", "microphone"):
                mix_into(microphone, room_tone(length, number * 7 + 1, 18), 0)
            if kind in ("meeting", "system"):
                mix_into(system, room_tone(length, number * 7 + 2, 6), 0)

            files = {}
            if kind == "meeting":
                write_m4a(microphone, folder / "microphone.m4a", work)
                write_m4a(system, folder / "system.m4a", work)
                mixed = array.array("h", ((a + b) // 2 for a, b in zip(microphone, system)))
                write_m4a(mixed, folder / "mix.m4a", work)
                files = {"microphone": "microphone.m4a", "system": "system.m4a", "mix": "mix.m4a"}
            elif kind == "microphone":
                write_m4a(microphone, folder / "microphone.m4a", work)
                files = {"microphone": "microphone.m4a"}
            elif kind == "system":
                write_m4a(system, folder / "system.m4a", work)
                files = {"system": "system.m4a"}
            else:
                name = conversation["fileName"]
                combined = array.array("h", (max(-32768, min(32767, a + b)) for a, b in zip(microphone, system)))
                mix_into(combined, room_tone(length, number * 7 + 3, 14), 0)
                write_m4a(combined, folder / name, work)
                files = {"imported": name}

        (folder / "timeline.json").write_text(json.dumps(
            {"id": conversation["id"], "duration": length / RATE, "files": files, "turns": timeline},
            ensure_ascii=False, indent=2,
        ))
        print(f"{conversation['id']}: {length / RATE:.1f} s", flush=True)


if __name__ == "__main__":
    main()
