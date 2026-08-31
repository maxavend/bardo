# Third-Party Notices

Bardo uses the following open-source software.

## Argmax Open-Source SDK / WhisperKit + SpeakerKit

- Repository: `argmaxinc/argmax-oss-swift`
- Version used by Bardo: `1.1.0`
- Products linked by Bardo: `WhisperKit`, `SpeakerKit`
- License: MIT
- Copyright: © 2024 argmax, inc.

Bardo links the `WhisperKit` and `SpeakerKit` products directly. It does not link the `ArgmaxOSS` umbrella product or `TTSKit`.

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

## FluidAudio

- Repository: `FluidInference/FluidAudio`
- Version used by Bardo: `0.15.6`
- Product linked by Bardo: `FluidAudio`
- License: Apache License 2.0

Bardo uses FluidAudio for the optional Parakeet-powered Instant transcription quality. The full Apache License 2.0 text is included with the upstream package and is available in the FluidAudio repository `LICENSE` file.

## Runtime-downloaded model artifacts

Bardo downloads Whisper, SpeakerKit/Pyannote, and optional Parakeet model artifacts at runtime. Bardo does not bundle those model files in the application. Their applicable upstream model terms should be reviewed separately before any future distribution strategy that bundles or redistributes those artifacts.
