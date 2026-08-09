import XCTest

@testable import CribeCore

/// Разбор ответа судьи. Сеть здесь не участвует: проверяется решение, а не транспорт.
final class DictionaryJudgeTests: XCTestCase {

    func testYesIsTakenWithItsReason() {
        let verdict = DictionaryJudge.parse("ДА|название продукта, записано на слух")
        XCTAssertTrue(verdict.learn)
        XCTAssertEqual(verdict.reason, "название продукта, записано на слух")
    }

    func testNoIsRefused() {
        XCTAssertFalse(DictionaryJudge.parse("НЕТ|человек изменил формулировку").learn)
    }

    func testAnswerWithoutReasonStillDecides() {
        XCTAssertTrue(DictionaryJudge.parse("ДА").learn)
        XCTAssertFalse(DictionaryJudge.parse("НЕТ").learn)
    }

    func testChattyAnswerIsReadByItsFirstLine() {
        // Модель иногда добавляет от себя: решение берём по первой строке, остальное не наше.
        XCTAssertTrue(DictionaryJudge.parse("ДА|термин\n\nЕсли нужно, могу пояснить.").learn)
    }

    func testUnparseableAnswerMeansNo() {
        // Сбой формата обязан значить «не добавлять»: лишняя пара в словаре молча портит
        // ВСЕ будущие диктовки, а пропущенную человек добавит сам.
        for answer in ["", "не уверен", "{\"learn\": true}", "yes"] {
            XCTAssertFalse(
                DictionaryJudge.parse(answer).learn,
                "неразобранный ответ «\(answer)» не имеет права пополнять словарь"
            )
        }
    }

    func testCaseAndSpacesDoNotChangeTheVerdict() {
        XCTAssertTrue(DictionaryJudge.parse("  да | бренд  ").learn)
    }

    // MARK: - Что видит судья

    func testJudgeSeesThePairAndTheSentenceAroundIt() {
        let input = DictionaryJudge.input(
            heard: "хероблок",
            meant: "heroblock",
            sentence: "поправим хероблок сегодня"
        )
        XCTAssertTrue(input.contains("хероблок"))
        XCTAssertTrue(input.contains("heroblock"))
        XCTAssertTrue(input.contains("поправим хероблок сегодня"), "фраза нужна для смысла")
    }

    func testPromptForbidsAddingOnDoubt() {
        // Правило, ради которого судья и заведён: цена ошибки несимметрична.
        XCTAssertTrue(DictionaryJudge.systemPrompt(language: .ru).contains("Сомневаешься"))
    }
}
