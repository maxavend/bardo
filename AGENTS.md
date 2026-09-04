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

- Do not animate live transcription word-by-word with blur/opacity/stagger effects. Live ASR updates are frequent and must render as lightweight plain text to protect UI responsiveness. Karaoke highlighting, if used, is reserved for playback of completed transcripts.
- For toolbar view switching such as Transcripción / Minuta, use native macOS segmented controls: either the native SwiftUI `Picker` with `.pickerStyle(.segmented)` or a native `NSSegmentedControl` with `segmentStyle = .capsule`. Do not recreate the selection pill, Liquid Glass morph, hover, pressed state, or segment animation with custom `Capsule`, `matchedGeometryEffect`, `GlassEffectContainer`, or `glassEffectID`; let SwiftUI/macOS AppKit own those states and transitions.
Prefer native SwiftUI/AppKit macOS controls and behavior over visual emulation. Preserve working behavior and avoid redesigning stable UI unless the change is a clear usability or platform-consistency improvement.

