enum ModelOperationPhase: Equatable, Sendable {
    case checking
    case downloading
    case preparing
    case loading
    case inference
}

enum ModelRecoveryDecision: Equatable, Sendable {
    case keepAndSurface
    case retryLoadAfterRepair
    case cancelled
}

enum ModelErrorKind: Equatable, Sendable {
    case network
    case load
    case other
}

enum ModelRecoveryPolicy {
    static func decision(
        wasComplete: Bool,
        phase: ModelOperationPhase,
        isCancellation: Bool,
        errorKind: ModelErrorKind
    ) -> ModelRecoveryDecision {
        if isCancellation {
            switch phase {
            case .checking, .downloading, .preparing, .loading, .inference:
                return .cancelled
            }
        }

        if wasComplete, errorKind == .load {
            return .retryLoadAfterRepair
        }

        return .keepAndSurface
    }
}
