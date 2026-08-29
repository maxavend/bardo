import Foundation
import XCTest
@testable import Bardo

final class TranscriptionContextPreferencesTests: XCTestCase {
    func testParserAcceptsPastedCommaSemicolonAndLineSeparatedTerms() {
        let terms = TranscriptionContextParser.terms(
            from: "Figma, SwiftUI; React\n\"hacer deploy\",  Auto   Layout  "
        )

        XCTAssertEqual(
            terms,
            ["Figma", "SwiftUI", "React", "hacer deploy", "Auto Layout"]
        )
    }

    func testParserRemovesDuplicatesWithoutChangingFirstSpelling() {
        let terms = TranscriptionContextParser.terms(
            from: "Figma, figma, FIGMA, Diseño, diseno, SwiftUI"
        )

        XCTAssertEqual(terms, ["Figma", "Diseño", "SwiftUI"])
    }

    func testPromptUsesOnlyEnabledCategoriesAndDeduplicatesAcrossThem() {
        let categories = [
            TranscriptionContextCategory(
                name: "UX/UI",
                termsText: "Figma, FigJam, design system",
                isEnabled: true
            ),
            TranscriptionContextCategory(
                name: "Frontend",
                termsText: "SwiftUI, Figma, staging",
                isEnabled: true
            ),
            TranscriptionContextCategory(
                name: "Not for this meeting",
                termsText: "legal, compliance",
                isEnabled: false
            )
        ]

        XCTAssertEqual(
            TranscriptionContextPreferences.activeTerms(in: categories),
            ["Figma", "FigJam", "design system", "SwiftUI", "staging"]
        )
        XCTAssertEqual(
            TranscriptionContextPreferences.promptText(from: categories),
            "Figma, FigJam, design system, SwiftUI, staging"
        )
    }

    func testStoragePreservesCategoriesAndAnIntentionalDeleteAll() throws {
        let suiteName = "TranscriptionContextPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let category = TranscriptionContextCategory(
            name: "Business",
            termsText: "KPI, ARR, MRR",
            isEnabled: true
        )

        TranscriptionContextPreferences.save([category], userDefaults: defaults)
        XCTAssertEqual(TranscriptionContextPreferences.load(userDefaults: defaults), [category])

        TranscriptionContextPreferences.save([], userDefaults: defaults)
        XCTAssertEqual(TranscriptionContextPreferences.load(userDefaults: defaults), [])
    }
}
