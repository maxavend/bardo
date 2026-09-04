# Bardo Meeting Minutes Model Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Bardo's local Meeting Minutes model available in development and require it during release model staging so incomplete apps fail before launch.

**Architecture:** Keep model weights outside Swift source and outside runtime downloads. A reviewed Hugging Face snapshot is staged under `Bardo/Resources/Models/Minutes/LFM2.5-1.2B-Instruct-4bit`; the existing resolver loads that bundle resource, with `Application Support` retained as a development fallback. The staging verifier validates the model layout and checksums before Xcode packages the app.

**Tech Stack:** Bash, Python standard library, XcodeGen, Swift 6, MLXSwiftLM, Hugging Face model snapshot.

**Spec:** Existing model ownership and offline staging requirements in `README.md` and `.github/scripts/stage-model-bundle.sh`.

## Global Constraints

- Use model ID `mlx-community/LFM2.5-1.2B-Instruct-4bit` and directory name `LFM2.5-1.2B-Instruct-4bit`.
- Require `config.json`, `tokenizer.json` or `tokenizer_config.json`, and at least one `.safetensors` file.
- Do not add a runtime network downloader or use the global Hugging Face cache.
- Preserve existing WhisperKit and SpeakerKit bundle validation and checksums.

---

### Task 1: Add a failing model-bundle validation fixture

**Files:**
- Create: `.github/scripts/test-stage-model-bundle.sh`

- [ ] Create a temporary voice bundle with the existing required voice directories and a manifest, but omit `Minutes/LFM2.5-1.2B-Instruct-4bit`.
- [ ] Assert that the staging verifier rejects the bundle.
- [ ] Add the minimal valid Meeting Minutes snapshot files and assert that verification succeeds.
- [ ] Run the fixture before changing the verifier and confirm the missing-minutes case currently fails because the old verifier accepts it.

### Task 2: Require Meeting Minutes during staging

**Files:**
- Modify: `.github/scripts/stage-model-bundle.sh`
- Modify: `.github/scripts/test-verify-dmg.sh` or the CI workflow to run the new fixture.

- [ ] Add `MINUTES_MODEL_ID` and validate the required snapshot layout below `Minutes/$MINUTES_MODEL_ID`.
- [ ] Ensure required Meeting Minutes files are represented in the manifest's checksummed asset list.
- [ ] Run the new fixture and confirm both rejection and acceptance cases pass.

### Task 3: Stage a local model snapshot for development

**Files:**
- Create or modify: a local staging helper under `.github/scripts/` only if needed after the source bundle contract is tested.
- Modify: `README.md` with the exact local staging command and expected source layout.

- [ ] Accept a reviewed local snapshot or full model bundle through an explicit environment variable.
- [ ] Stage it into `Bardo/Resources/Models/Minutes/LFM2.5-1.2B-Instruct-4bit`.
- [ ] Regenerate the Xcode project and build Bardo with the staged resource.

### Task 4: Verify the packaged app

**Files:**
- Modify: `.github/scripts/verify-dmg.sh` only if the existing validation path needs explicit minutes reporting.

- [ ] Build the app with the staged model.
- [ ] Confirm `Bardo.app/Contents/Resources/Models/Minutes/LFM2.5-1.2B-Instruct-4bit` contains the validated snapshot.
- [ ] Run the local Meeting Minutes setup path and confirm it no longer reports an incomplete model.

