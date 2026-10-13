# Bardo agent guardrails

Bardo is a macOS app built with Swift 6 / SwiftUI. The project targets macOS 15+ and CI builds with Xcode 26.6.

## macOS API compatibility

- Treat diagnostics from the active Xcode SDK as the source of truth for platform availability.
- Never use an API the SDK marks unavailable on macOS, even inside `if #available(macOS ...)`.
- `SearchToolbarBehavior.minimize` / `.searchToolbarBehavior(.minimize)` is unavailable on macOS and must not be used in Bardo.
- For SwiftUI toolbar search on macOS, prefer `.searchable(..., placement: .toolbar)`.
- If Bardo needs Calendar-style search that collapses to a button and expands on click, use the native AppKit `NSSearchToolbarItem` behavior instead of an unavailable SwiftUI search-toolbar API.
- Before adding a newer SwiftUI API in a UI refactor, verify its macOS availability in the project’s active Xcode SDK.

## UI refactor principle

- Live transcription must stay lightweight: settled text renders as plain `Text`. Only a passage that has just arrived may reveal its words, once, by changing their opacity inside a single `Text` (`StreamingRevealText`: 60 ms per word, 350 ms fade, at most 1.5 s per passage, still under Reduce Motion). Never add per-word views, blur or replays to live text. Karaoke highlighting is reserved for playback of completed transcripts.
- Prefer native SwiftUI/AppKit macOS controls and behavior over visual emulation. Preserve working behavior and avoid redesigning stable UI unless the change is a clear usability or platform-consistency improvement.
