import XCTest
@testable import Bardo

final class TranscriptionLanguagePreferenceTests: XCTestCase {
    func testFixedSpanishDisablesLanguageDetection() {
        let policy = TranscriptionLanguagePolicy.make(
            preference: .spanish,
            lockedLanguageCode: nil
        )

        XCTAssertEqual(policy.languageCode, "es")
        XCTAssertFalse(policy.detectsLanguage)
    }

    func testAutomaticLanguageDetectsOnlyUntilLanguageIsLocked() {
        let initial = TranscriptionLanguagePolicy.make(
            preference: .automatic,
            lockedLanguageCode: nil
        )
        let locked = TranscriptionLanguagePolicy.make(
            preference: .automatic,
            lockedLanguageCode: "es"
        )

        XCTAssertNil(initial.languageCode)
        XCTAssertTrue(initial.detectsLanguage)
        XCTAssertEqual(locked.languageCode, "es")
        XCTAssertFalse(locked.detectsLanguage)
    }

    func testFixedPreferenceWinsOverPreviouslyDetectedLanguage() {
        let policy = TranscriptionLanguagePolicy.make(
            preference: .spanish,
            lockedLanguageCode: "en"
        )

        XCTAssertEqual(policy.languageCode, "es")
        XCTAssertFalse(policy.detectsLanguage)
    }

    func testPreferenceResolutionKeepsAutomaticAvailableAsExplicitChoice() {
        XCTAssertEqual(TranscriptionLanguagePreference.resolve("auto"), .automatic)
        XCTAssertEqual(TranscriptionLanguagePreference.resolve("es"), .spanish)
        XCTAssertEqual(TranscriptionLanguagePreference.resolve("en"), .english)
    }
}
