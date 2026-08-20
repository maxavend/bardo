# Third-Party Notices

Bardo uses the following open-source software.

## Argmax Open-Source SDK / WhisperKit

- Repository: `argmaxinc/argmax-oss-swift`
- Version used by Bardo: `1.0.0`
- Product linked by Bardo: `WhisperKit`
- License: MIT
- Copyright: © 2024 argmax, inc.

The upstream MIT license requires preservation of its copyright and permission notice in copies or substantial portions of the software. See the upstream `LICENSE` file in the pinned package for the complete license text.

Bardo does not link the `ArgmaxOSS` umbrella product, `SpeakerKit`, or `TTSKit` in Phase 5.

Model files downloaded by WhisperKit are separate artifacts. Their applicable terms must be reviewed before Bardo is distributed publicly with bundled model files. Phase 5 downloads models at runtime and does not bundle them in the application.
