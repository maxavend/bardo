#!/usr/bin/env python3
"""Polishes the seeded transcripts against the script they were synthesized from.

    python3 -I tools/portfolio/polish_transcripts.py <conversations.json> <audio folder> <Library folder>

Whisper and SpeakerKit run for real in the seed, so their output has the usual rough
edges with synthetic voices: a few words misheard, a phrase hallucinated in a silence, two
similar voices merged. This keeps the recognized text and timing, and:

- gives every segment the speaker whose script turn it overlaps most, and drops segments
  that overlap no turn (or, per track, a turn from the other track);
- keeps one speaker per persona and removes speakers left without segments;
- applies the corrections below as manual edits, so Bardo shows them as edited and keeps
  the original recognition, as when a person corrects a transcript;
- records the processing time of a model that is already optimized for the Mac (the seed's
  first run includes Core ML's one-time optimization).
"""
import json
import sys
import uuid
from pathlib import Path

CORRECTIONS = {
    "revision-onboarding": [("Lombarding", "el onboarding"), ("de el onboarding", "del onboarding"),
                            ("El root", "El RUT")],
    "test-usabilidad-3": [("root", "RUT"), ("New York", "Ñuñoa"), ("Pero si vamos", "Pero sigamos"),
                          ("MMM", "Mmm")],
    "nota-reprogramacion": [("La continuidad", "la continuidad")],
    "sintesis-javiera": [("¿Coincide con lo que contó Carolina?", "Coincide con lo que contó Carolina.")],
}


def overlap(segment, turn):
    return min(segment["endTime"], turn["end"]) - max(segment["startTime"], turn["start"])


def main() -> None:
    script = json.loads(Path(sys.argv[1]).read_text())
    audio, library = Path(sys.argv[2]), Path(sys.argv[3])
    by_title = {conversation["title"]: conversation for conversation in script["conversations"]}

    for folder in sorted(library.iterdir()):
        transcript_url = folder / "transcript.json"
        if not transcript_url.exists():
            continue
        manifest = json.loads((folder / "manifest.json").read_text())
        recording = manifest.get("recording", manifest)
        conversation = by_title[recording["title"]]
        turns = json.loads((audio / conversation["id"] / "timeline.json").read_text())["turns"]
        document = json.loads(transcript_url.read_text())
        transcript = document["transcript"]
        per_track = transcript["metadata"].get("trackMode") == "perTrack"
        speakers = transcript.get("speakers", [])
        names = conversation.get("names", {})

        # One speaker per persona: Bardo's own "You" for `tu` per track, else the
        # speaker already named after the persona, else a new unnamed speaker.
        persona_speaker = {}
        if speakers:
            for persona in dict.fromkeys(turn["persona"] for turn in turns):
                if per_track and persona == "tu":
                    match = next((s for s in speakers if s.get("role") == "localUser"), None)
                else:
                    match = next((s for s in speakers if names.get(persona) and s.get("name") == names[persona]), None)
                if match is None:
                    match = {"id": str(uuid.uuid4()).upper()}
                    if per_track:
                        match["role"] = "others"
                    speakers.append(match)
                persona_speaker[persona] = match["id"]

        kept = []
        for segment in transcript["segments"]:
            scored = [(overlap(segment, turn), turn["persona"]) for turn in turns]
            best, persona = max(scored)
            if best <= 0:
                continue
            if per_track and segment.get("source") and (segment["source"] == "microphone") != (persona == "tu"):
                continue
            if persona_speaker:
                segment["speakerID"] = persona_speaker[persona]
            for find, replace in CORRECTIONS.get(conversation["id"], []):
                current = segment.get("editedText") or segment["text"]
                if find in current:
                    segment["editedText"] = current.replace(find, replace)
            kept.append(segment)
        audio_duration = max(turn["end"] for turn in turns)
        transcript["metadata"]["processingDuration"] = round(2.5 + audio_duration * 0.065, 2)
        if transcript.get("diarizationMetadata"):
            transcript["diarizationMetadata"]["processingDuration"] = round(0.6 + audio_duration * 0.012, 2)
        dropped = len(transcript["segments"]) - len(kept)
        transcript["segments"] = kept
        used = {segment.get("speakerID") for segment in kept}
        transcript["speakers"] = [s for s in speakers if s["id"] in used]

        transcript_url.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True))
        edits = sum(1 for segment in kept if segment.get("editedText"))
        print(f"{conversation['id']}: {len(kept)} segments ({dropped} dropped), "
              f"{len(transcript['speakers'])} speakers, {edits} edited")


if __name__ == "__main__":
    main()
