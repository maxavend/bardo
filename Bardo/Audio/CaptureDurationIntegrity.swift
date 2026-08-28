import Foundation

enum CaptureDurationIntegrityError: Error, LocalizedError, Equatable, Sendable {
    case truncated(expected: TimeInterval, finalized: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .truncated(let expected, let finalized):
            return "The finalized audio is shorter than the captured timeline (captured \(String(format: "%.2f", expected))s, file \(String(format: "%.2f", finalized))s). Bardo preserved the capture for recovery instead of publishing incomplete audio."
        }
    }
}

enum CaptureDurationIntegrity {
    /// Encoders may differ by a few frames. Only reject a material loss: at least 0.75s and
    /// more than 2% of the captured timeline. The guard is deliberately fail-closed for
    /// important recordings while avoiding false positives from codec priming/rounding.
    static func validate(expected: TimeInterval, finalized: TimeInterval) throws {
        guard expected.isFinite, finalized.isFinite, expected > 0, finalized > 0 else { return }
        let missing = expected - finalized
        let relativeLoss = missing / expected
        if missing > 0.75, relativeLoss > 0.02 {
            throw CaptureDurationIntegrityError.truncated(expected: expected, finalized: finalized)
        }
    }
}
