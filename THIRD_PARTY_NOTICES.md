# Third-Party Notices

Bardo uses the following open-source software.

## Argmax Open-Source SDK / WhisperKit + SpeakerKit

- Repository: `argmaxinc/argmax-oss-swift`
- Version used by Bardo: `1.0.0`
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

## Runtime-downloaded model artifacts

Phase 5 downloads Whisper model/tokenizer artifacts at runtime. Phase 6 additionally downloads SpeakerKit/Pyannote model artifacts at runtime. Bardo does not bundle those model files in the application. Their applicable upstream terms should be reviewed separately before any future distribution strategy that bundles or redistributes those artifacts.
