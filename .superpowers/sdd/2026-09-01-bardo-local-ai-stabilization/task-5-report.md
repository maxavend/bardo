# Task 5 report — Harden SpeakerKit validation and repair

## Implemented

- Added a `SpeakerDiarizationEngine` seam and `SpeakerDiarizationOperations` factory so tests can exercise model lifecycle without network access or real Core ML assets.
- Kept the SpeakerKit model root owned by `BardoModelStore` and configured the production engine to use that private root as its custom download base.
- Replaced filename-only readiness with a two-step check: required private assets must be present, then a no-download engine must successfully load them and report `isLoaded`.
- Split model setup into explicit download and load phases.
- Added bounded recovery: a complete private cache whose load fails clears the cached engine, resets only the SpeakerKit model directory, creates a fresh engine, and performs exactly one download/load repair attempt.
- Network failures during an initial download and cancellations do not reset or delete the private cache and do not retry.
- Invalid or failed engines are never retained; only a successfully loaded engine is cached for diarization.
- Warm-up now uses the same setup path and leaves `ManagedModelState.failed` when validation/repair fails instead of publishing readiness.
- Added the actionable `speakerModelsNotLoaded` error and exposed the model state/reset seam needed by callers and tests.
- Routed the actual diarization operation through the hardened setup lifecycle.

## Tests

Added/updated coverage for:

- complete versus partial private SpeakerKit assets;
- complete cache that does not become loaded;
- complete-cache load failure with engine invalidation and one repair attempt;
- initial network failure preserving a partial cache;
- cancellation preserving the cache and skipping load;
- warm-up remaining in a failed state after repair load failure;
- delegation to the shared `ModelRecoveryPolicy`.

The new tests use injected engines and no network calls.

## Quick checks

- `swiftc -parse` for the changed service and SpeakerKit tests: passed.
- `git diff --check`: passed.
- `xcodebuild` and SwiftPM were intentionally not run per the task instruction.
