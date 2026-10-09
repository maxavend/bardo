# Whisper Large v3 Turbo benchmark protocol

This document records the physical benchmark required before changing the
default long-form profile. It intentionally contains no invented throughput or
quality results.

## Candidate profiles

| Profile | Incremental chunk | Buffered chunks | Workers | VAD | Fallbacks |
| --- | ---: | ---: | ---: | --- | ---: |
| 4 GB / constrained | 90 s | 1 | 4 | yes | 5 |
| 6 GB / constrained | 90 s | 1 | 4 | yes | 5 |
| 8 GB / constrained | 90 s | 1 | 4 | yes | 5 |
| 12 GB / balanced | 90 s | 1 | 4 | yes | 5 |
| 16 GB / Apple Silicon | 120 s | 2 | 8 | yes | 5 |

The runtime profile is selected from physical memory, while the benchmark
must also record the actual chip, thermal state, OS version and available
memory. A profile change requires evidence rather than a guess based on model
size.

## Required measurements

For the same private, consented audio fixtures, record:

- cold load, warm load and end-to-end elapsed seconds;
- audio seconds, ASR seconds and real-time factor;
- peak resident memory and whether memory pressure occurred;
- fallback count, decoding windows, VAD windows and emitted word count;
- transcript WER/CER against the fixture reference;
- punctuation, language and word-timestamp regressions;
- fan/thermal behavior over a long-form fixture.

## Acceptance gate

No candidate is accepted solely because it is faster. Keep the candidate only
if it does not regress WER/CER, language detection, word timestamps or
conversation reconstruction, and if peak memory remains within the device's
safe operating envelope. Attach raw logs and fixture identifiers to the
release evidence; never commit private audio.

## Current status

Pending physical Apple Silicon measurements. The code defaults are deliberately
conservative and are observable through `WhisperTranscriptionMetrics`.
