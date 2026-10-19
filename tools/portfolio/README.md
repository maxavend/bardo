# Portfolio captures

Builds a realistic sample Library and captures Bardo's main flows in light and dark, at
Retina resolution, for a UX/UI portfolio. Nothing here touches your own Library or
settings: everything runs against isolated homes and the `com.maxavend.bardo.portfolio`
bundle identifier.

## The sample data

`conversations.json` is the script: eight conversations of a fictional product team
("Nido", home nursing visits) over one week, from user research to a design review. Each
conversation is a real recording kind (a meeting with microphone and Mac audio tracks, a
microphone note, Mac audio only, an imported file) and a real state (transcribed with or
without named speakers, untranscribed, failed).

1. `generate_audio.py` synthesizes every turn with a different macOS voice and writes the
   tracks Bardo would have captured or imported.
2. `PortfolioSeedTests` publishes them into a Library and transcribes them with the real
   Whisper and SpeakerKit models.
3. `polish_transcripts.py` keeps the recognized text and timing but names speakers after
   the script, drops phrases hallucinated in silences and records a few misheard words as
   manual corrections (Bardo shows them as edited, with the original kept).
4. `prepare_homes.sh` adds an empty home and a home with an interrupted recording, and
   sets the portfolio build's preferences.

## Capturing

`capture.py` launches the Debug build once per screen and state through the design review
(`Bardo/App/DesignReview.swift`), which places the window on the Retina screen, draws it as
active and saves it with its sheets and popovers. It needs no Screen Recording
permission. Run it under `caffeinate -du`: WindowServer stops compositing Liquid Glass
while the display sleeps. For the sidebar's accent the app must really be frontmost, so
leave the Mac alone while it runs.

```bash
caffeinate -du python3 -I tools/portfolio/capture.py <Bardo.app> <homes> <output> [filter]
```
