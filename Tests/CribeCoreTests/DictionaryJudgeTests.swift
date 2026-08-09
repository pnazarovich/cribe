import XCTest

@testable import CribeCore

/// Разбор ответа судьи. Сеть здесь не участвует: проверяется решение, а не транспорт.
final class DictionaryJudgeTests: XCTestCase {

    private func observed(_ pairs: [(String, String, TimeInterval)]) -> [ObservedCorrection] {
        pairs.map {
            ObservedCorrection(correction: Correction(heard: $0.0, meant: $0.1), after: $0.2)
        }
    }

    // MARK: - Разбор вердиктов

    func testEachCorrectionGetsItsOwnVerdictByNumber() {
        let answer = """
            1|ДА|название продукта, записано на слух
            2|НЕТ|человек изменил формулировку
            """
        let verdicts = DictionaryJudge.parse(answer, count: 2)
        XCTAssertEqual(verdicts.map(\.learn), [true, false])
        XCTAssertEqual(verdicts[0].reason, "название продукта, записано на слух")
    }

    func testOutOfOrderAnswerIsMatchedByNumberNotByPosition() {
        // Модель вправе ответить не по порядку — номер сильнее места в списке.
        let verdicts = DictionaryJudge.parse("2|ДА|термин\n1|НЕТ|обычное слово", count: 2)
        XCTAssertEqual(verdicts.map(\.learn), [false, true])
    }

    func testMissingLineMeansNo() {
        // Модель ответила про одну правку из трёх: остальные две — отказ, а не догадка.
        let verdicts = DictionaryJudge.parse("2|ДА|бренд", count: 3)
        XCTAssertEqual(verdicts.map(\.learn), [false, true, false])
    }

    func testUnparseableAnswerAddsNothing() {
        // Сбой формата обязан значить «не добавлять»: лишняя пара в словаре молча портит
        // ВСЕ будущие диктовки, а пропущенную человек добавит сам.
        for answer in ["", "не уверен", "{\"1\": true}", "ДА", "yes"] {
            XCTAssertEqual(
                DictionaryJudge.parse(answer, count: 2).map(\.learn), [false, false],
                "неразобранный ответ «\(answer)» не имеет права пополнять словарь"
            )
        }
    }

    func testNumberOutsideTheListIsIgnored() {
        XCTAssertEqual(DictionaryJudge.parse("7|ДА|термин", count: 2).map(\.learn), [false, false])
    }

    func testCaseAndSpacesDoNotChangeTheVerdict() {
        XCTAssertTrue(DictionaryJudge.parse("  1 | да | бренд  ", count: 1)[0].learn)
    }

    func testVerdictWithoutReasonStillDecides() {
        XCTAssertTrue(DictionaryJudge.parse("1|ДА", count: 1)[0].learn)
    }

    // MARK: - Что видит судья

    func testJudgeSeesEveryPairNumberedWithItsTiming() {
        let input = DictionaryJudge.input(
            observed([("хероблок", "heroblock", 4), ("добавлять", "gjrть", 12)]),
            sentence: "поправим хероблок сегодня"
        )
        XCTAssertTrue(input.contains("1. «хероблок» → «heroblock» (через 4 с)"))
        XCTAssertTrue(input.contains("2. «добавлять» → «gjrть» (через 12 с)"))
        XCTAssertTrue(input.contains("поправим хероблок сегодня"), "фраза нужна для смысла")
    }

    func testPromptExplainsWhyTimingMatters() {
        // Время — довод: правят сразу, а работать поверх начинают потом.
        XCTAssertTrue(DictionaryJudge.systemPrompt(language: .ru).contains("Время — довод"))
    }

    func testPromptForbidsAddingOnDoubt() {
        // Правило, ради которого судья и заведён: цена ошибки несимметрична.
        XCTAssertTrue(DictionaryJudge.systemPrompt(language: .ru).contains("Сомневаешься"))
    }
}
