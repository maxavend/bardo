import XCTest
@testable import Bardo

final class ModelRecoveryPolicyTests: XCTestCase {
    private struct DecisionCase {
        let name: String
        let wasComplete: Bool
        let phase: ModelOperationPhase
        let isCancellation: Bool
        let errorKind: ModelErrorKind
        let expected: ModelRecoveryDecision
    }

    func testDecisionTableCoversBoundedRecoveryCases() {
        let cases = [
            DecisionCase(
                name: "complete cache load failure",
                wasComplete: true,
                phase: .loading,
                isCancellation: false,
                errorKind: .load,
                expected: .retryLoadAfterRepair
            ),
            DecisionCase(
                name: "first download network failure",
                wasComplete: false,
                phase: .downloading,
                isCancellation: false,
                errorKind: .network,
                expected: .keepAndSurface
            ),
            DecisionCase(
                name: "first download load failure",
                wasComplete: false,
                phase: .downloading,
                isCancellation: false,
                errorKind: .load,
                expected: .keepAndSurface
            ),
            DecisionCase(
                name: "cancellation while checking",
                wasComplete: true,
                phase: .checking,
                isCancellation: true,
                errorKind: .load,
                expected: .cancelled
            ),
            DecisionCase(
                name: "cancellation while downloading",
                wasComplete: true,
                phase: .downloading,
                isCancellation: true,
                errorKind: .load,
                expected: .cancelled
            ),
            DecisionCase(
                name: "cancellation while preparing",
                wasComplete: true,
                phase: .preparing,
                isCancellation: true,
                errorKind: .load,
                expected: .cancelled
            ),
            DecisionCase(
                name: "cancellation while loading",
                wasComplete: true,
                phase: .loading,
                isCancellation: true,
                errorKind: .load,
                expected: .cancelled
            ),
            DecisionCase(
                name: "cancellation during inference",
                wasComplete: true,
                phase: .inference,
                isCancellation: true,
                errorKind: .load,
                expected: .cancelled
            )
        ]

        for testCase in cases {
            let decision = ModelRecoveryPolicy.decision(
                wasComplete: testCase.wasComplete,
                phase: testCase.phase,
                isCancellation: testCase.isCancellation,
                errorKind: testCase.errorKind
            )

            XCTAssertEqual(decision, testCase.expected, testCase.name)
        }
    }
}
