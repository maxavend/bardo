import Foundation
import XCTest
@testable import Bardo

final class LocalizationTableTests: XCTestCase {
    func testSpanishTranslatesEveryKeyWithMatchingPlaceholders() throws {
        let english = try table("en")
        let spanish = try table("es")

        XCTAssertEqual(Set(english.keys), Set(spanish.keys), "Both languages must define the same keys")
        for (key, translation) in spanish {
            XCTAssertEqual(
                placeholders(in: translation),
                placeholders(in: key),
                "Placeholders differ for \"\(key)\""
            )
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
        }
    }

    func testUserFacingErrorsResolveInSpanish() throws {
        let spanish = try table("es")
        XCTAssertEqual(spanish["Another Bardo recording is already active."], "Ya hay otra grabación de Bardo en curso.")
        XCTAssertEqual(spanish["Bardo could not recover %@: %@"], "Bardo no pudo recuperar %@: %@")
        XCTAssertNotNil(spanish["The %@ track skipped %lld short audio buffers while the Mac was busy."])
    }

    private func table(_ language: String) throws -> [String: String] {
        let bundle = Bundle(for: LibraryViewModel.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "Missing \(language) table"
        )
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        return dictionary
    }

    /// Format specifiers in order, normalizing positional forms like %1$@.
    private func placeholders(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(@|lld|ld|d|lf|f|\.\d+f)"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }.sorted()
    }
}
