# Third-Party Notices

Bardo uses the following open-source software.

## MLX Swift LM and LFM2.5

- Runtime repository: `ml-explore/mlx-swift-lm`
- Version used by Bardo: `3.31.3`
- Products linked by Bardo: `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`
- Model asset: `mlx-community/LFM2.5-1.2B-Instruct-4bit`
- Pinned model revision: `125e006d991147f3b432249d1bdf0821987f12b0`
- Model architecture: `lfm2`
- Model quantization: 4-bit
- Distribution: downloaded during first-run setup into Bardo's private Application Support directory; an offline bundled snapshot is optional.
- Upstream runtime license and notices: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
- Model terms: review the model repository's license and model card for the downloaded artifact.

This notice records the intended local runtime/model boundary. It does not replace the upstream license text or authorize redistribution where the model's upstream terms do not permit it.

## Argmax Open-Source SDK / WhisperKit + SpeakerKit

- Repository: `argmaxinc/argmax-oss-swift`
- Version used by Bardo: `1.1.0`
- Products linked by Bardo: `WhisperKit`, `SpeakerKit`
- License: MIT
- Copyright: © 2024 argmax, inc.

Bardo links the `WhisperKit` and `SpeakerKit` products directly. It does not link the `ArgmaxOSS` umbrella product or `TTSKit` in Phase 6.

### MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Runtime model artifacts

Bardo downloads `large-v3-v20240930_turbo_632MB` through WhisperKit and `pyannote-v3+plda-v4` through SpeakerKit during first-run setup into its private Application Support model roots. Voice artifacts are not required in the DMG and are not taken from a global Hugging Face cache. Upstream model cards, licenses, and redistribution terms remain applicable to each downloaded artifact.
