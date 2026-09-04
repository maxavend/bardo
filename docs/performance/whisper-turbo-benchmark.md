# Whisper Large v3 Turbo physical benchmark

This protocol exists to choose Bardo's fastest safe Whisper profile from
physical measurements instead of guessing from model size or RAM.

The production default remains unchanged until a physical Apple Silicon run
passes the quality, memory, thermal and stability gates below.

## What the harness measures

The benchmark runs the actual Bardo Release executable and the same
\`WhisperTranscriptionService\` used by the application. Diagnostic mode records:

- model preparation time;
- cold and warm model-load time;
- time to first text (TTFT);
- Whisper inference time and ASR real-time factor (RTF);
- end-to-end time and end-to-end RTF;
- peak resident memory and kernel memory-pressure events;
- thermal state at start, worst observed state and end;
- progress samples pairing processed audio time with wall time, memory and
  thermal state for long-form slowdown analysis;
- decoding fallbacks, VAD windows, segment count and word count;
- detected language and word-timestamp coverage;
- optional WER/CER against a human reference transcript.

The runner writes after every completed run so partial evidence survives a
later failure.

## Environment isolation

Production behavior is not changed by the benchmark. Overrides are honored only
when diagnostic mode is explicitly enabled or a benchmark audio path is
present.

The supported diagnostic overrides are:

\`\`\`text
BARDO_WHISPER_WORKERS
BARDO_WHISPER_CHUNK_SECONDS
BARDO_WHISPER_BUFFERED_CHUNKS
\`\`\`

Normal app launches keep the existing memory-based profile.

WhisperKit compute units are made explicit in Bardo:

\`\`\`text
Mel preprocessing  -> CPU + GPU
Audio encoder      -> CPU + Neural Engine
Text decoder       -> CPU + Neural Engine
\`\`\`

This matches the intended Apple Silicon Core ML allocation and prevents a
future dependency update from silently changing Bardo's hardware policy.

## Fixture

Use the same private, consented audio for every candidate in one matrix.

Recommended fixtures:

1. 10–20 minute Spanish conversation for worker/chunk tuning.
2. 45–90 minute meeting for sustained fanless MacBook Air thermal testing.
3. Optional human-corrected transcript for the short fixture to calculate
   WER/CER.

Do not commit private audio or reference transcripts.

For reproducible comparison, connect the Mac to power, disable Low Power Mode,
close other heavy ML/video workloads and start the matrices from a comparable
thermal state.

## One-command runner

From the repository root:

\`\`\`bash
bash Scripts/benchmark-whisper.sh \
  --audio ~/Desktop/bardo-benchmark.m4a \
  --matrix workers
\`\`\`

The script:

1. generates the Xcode project with XcodeGen;
2. builds Bardo in Release;
3. builds with `-skipPackagePluginValidation` so Xcode's headless trust prompt for the
   exact-version-pinned MLX package plugin cannot block the physical benchmark;
4. runs the Release executable directly in benchmark mode;
5. bootstraps Whisper once before timed profiles so download/Core ML
   specialization does not bias profile comparisons;
6. executes the requested profile matrix;
7. writes JSON, per-run CSV, summary CSV, build log and benchmark log.

By default results are written under:

\`\`\`text
~/Desktop/BardoWhisperBenchmarks/<timestamp>-<matrix>/
├── benchmark.json
├── benchmark-runs.csv
├── benchmark-summary.csv
├── benchmark.log
└── build.log
\`\`\`

The local Release build is kept in \`.benchmark-derived-data/\`, which is
gitignored. Subsequent matrices can pass \`--skip-build\` to reuse it when HEAD
has not changed.

## Phase 1 — workers

Run:

\`\`\`bash
bash Scripts/benchmark-whisper.sh \
  --audio ~/Desktop/bardo-benchmark.m4a \
  --reference ~/Desktop/bardo-benchmark-reference.txt \
  --matrix workers
\`\`\`

This compares:

| Chunk | Buffered chunks | Workers |
| ---: | ---: | ---: |
| 120 s | 2 | 4 |
| 120 s | 2 | 6 |
| 120 s | 2 | 8 |

Each profile defaults to three runs:

- run 1: cold model load after the model has already been installed/prewarmed;
- runs 2–3: warm model reuse.

Choose the worker candidate using median warm ASR RTF, not the single fastest
run. Reject a candidate with material quality regression, memory pressure or
unacceptable thermal behavior.

## Phase 2 — chunk and buffer

After the worker winner is known, for example 6:

\`\`\`bash
bash Scripts/benchmark-whisper.sh \
  --audio ~/Desktop/bardo-benchmark.m4a \
  --reference ~/Desktop/bardo-benchmark-reference.txt \
  --matrix chunks \
  --worker 6 \
  --skip-build
\`\`\`

This compares:

| Chunk | Buffered chunks |
| ---: | ---: |
| 90 s | 1 |
| 90 s | 2 |
| 120 s | 1 |
| 120 s | 2 |
| 150 s | 1 |
| 150 s | 2 |

The selected worker count remains fixed so the second matrix isolates chunking
and buffering effects.

## Phase 3 — sustained long-form

Take the best two profiles from phases 1–2 and use a 45–90 minute fixture.

Example:

\`\`\`bash
bash Scripts/benchmark-whisper.sh \
  --audio ~/Desktop/bardo-benchmark-60m.m4a \
  --matrix long \
  --profiles 120:2:6,150:1:6 \
  --repetitions 1 \
  --cooldown 30 \
  --skip-build
\`\`\`

Long profile syntax is:

\`\`\`text
chunkSeconds:bufferedChunks:workers
\`\`\`

The runner records progress samples over the whole transcription. Compare early
and late processed-audio throughput rather than relying only on final average
RTF. A profile that starts faster but degrades strongly as the fanless MacBook
Air heats up is not the winner.

Between profiles the runner waits the configured fixed cooldown and, if the
system is still at \`serious\` or \`critical\` thermal state, waits for recovery
for up to two additional minutes. The observed state is always retained in the
result.

For the highest-confidence long-form comparison, run each finalist from a
similar starting temperature in separate benchmark invocations as well.

## Single-profile diagnostic run

To validate one explicit profile:

\`\`\`bash
BARDO_WHISPER_WORKERS=6 \
BARDO_WHISPER_CHUNK_SECONDS=120 \
BARDO_WHISPER_BUFFERED_CHUNKS=2 \
bash Scripts/benchmark-whisper.sh \
  --audio ~/Desktop/bardo-benchmark.m4a \
  --matrix single
\`\`\`

## Reading the output

\`benchmark-summary.csv\` is the fastest comparison surface. It contains:

- median, standard deviation, minimum and maximum ASR RTF;
- median end-to-end RTF;
- median TTFT;
- maximum observed resident memory;
- memory-pressure occurrence;
- worst thermal state;
- median WER/CER when a reference was provided.

\`benchmark-runs.csv\` preserves every individual run.

\`benchmark.json\` is the complete evidence record. It also includes hardware,
macOS version, Git SHA and long-form progress samples.

RTF examples:

\`\`\`text
RTF 0.10 = 10 minutes of audio in ~1 minute of inference
RTF 0.05 = 10 minutes of audio in ~30 seconds of inference
\`\`\`

Lower is better, but RTF alone never decides the winner.

## Acceptance gate

A candidate can become the certified device profile only when all of the
following hold:

1. **Performance:** median warm RTF is meaningfully better or equal to the
   alternatives.
2. **Quality:** no material WER/CER regression, language regression or loss of
   word-timestamp coverage.
3. **Memory:** no memory-pressure event and peak resident memory stays inside a
   safe operating envelope.
4. **Thermal:** sustained throughput does not collapse under the long-form
   fixture; \`serious\`/\`critical\` thermal behavior is treated as a warning,
   not hidden by a good initial RTF.
5. **Stability:** no crash, hang, Core ML failure or corrupted transcript.
6. **Reproducibility:** the conclusion comes from repeated runs on the same
   fixture and is attached to the tested Git SHA.

Do not select a profile merely because it uses more workers.

## Current candidate defaults

| Device class | Incremental chunk | Buffered chunks | Workers | VAD | Fallbacks |
| --- | ---: | ---: | ---: | --- | ---: |
| <16 GB constrained | 90 s | 1 | 4 | yes | 5 |
| >=16 GB Apple Silicon | 120 s | 2 | 8 | yes | 5 |

These remain production defaults. The MacBook Air M5 / 16 GB profile is not
certified until the physical procedure above is completed and reviewed.
