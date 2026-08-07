import XCTest
@testable import CribeCore

/// Набор «что словарь уже знает». Ошибка здесь тихая и потому неприятная: слово перестаёт
/// предлагаться, хотя в словаре его нет, — или наоборот предлагается уже добавленное.
final class DictionaryTokensTests: XCTestCase {
    private let entries = [
        DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"]),
        DictionaryEntry(canonical: "pull request", variants: ["пул реквест"]),
    ]

    /// Многословный термин закрывает и свои отдельные слова.
    func testKnownTokensCoverIndividualWords() {
        let known = DictionaryTokens.known(entries)
        XCTAssertTrue(known.contains("pull"))
        XCTAssertTrue(known.contains("request"))
        XCTAssertTrue(known.contains("pull request"))
    }

    /// Варианты знакомы наравне с канонической формой — их-то человек и произносит.
    func testVariantsAreKnownToo() {
        let known = DictionaryTokens.known(entries)
        XCTAssertTrue(known.contains("гитхаб"))
        XCTAssertTrue(known.contains("пул"))
    }

    /// Регистр не имеет значения: в речи его нет вовсе.
    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(DictionaryTokens.known(entries).contains("github"))
    }
}
