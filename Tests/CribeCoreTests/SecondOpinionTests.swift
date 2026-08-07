import XCTest

@testable import CribeCore

/// Правило второго мнения. Все числа здесь — из замеров на настоящих записях владельца
/// (2026-08-08, три записи), а не придуманы: синтетическая речь для этой задачи негодна —
/// на ней фича дважды «чинилась» ложно (см. коммит 441156a).
final class SecondOpinionTests: XCTestCase {

    // MARK: - Кого спрашивать

    func testRussianAsksUkrainian() {
        XCTAssertEqual(Language.ru.neighbour, .uk)
    }

    func testEnglishHasNoNeighbour() {
        XCTAssertNil(Language.en.neighbour, "с английским такой беды не наблюдалось")
    }

    func testUkrainianSessionHasNoNeighbourUntilMeasured() {
        // Обратное направление не включено намеренно: судьёй там оказалась бы turbo —
        // модель СЛАБЕЕ украинской large-v3, да ещё и склонная тянуть украинское
        // в русское написание. Замеров нет, а без них на этой задаче уже ошибались.
        XCTAssertNil(Language.uk.neighbour)
    }

    // MARK: - Кого проверять

    func testConfidentlyOwnPiecesAreNotDoubted() {
        // Замеренные уверенности на настоящих русских фразах боевого пути.
        for confidence in [Float(-0.000), -0.001, -0.001] {
            XCTAssertFalse(
                SecondOpinion.isSuspicious(confidence: confidence, duration: 6.52),
                "уверенность \(confidence) — это чистый свой язык, второе мнение стоит времени"
            )
        }
    }

    func testPieceWithForeignInsertIsDoubted() {
        // Фраза, где русское начало переходит в украинскую вставку: модель ответила
        // «русский», но лишь на −0.183.
        XCTAssertTrue(SecondOpinion.isSuspicious(confidence: -0.183, duration: 4.94))
    }

    func testShortPiecesAreLeftAlone() {
        // «Пока.» длиной в секунду: определение соврало (en, −0.300) — то есть дало ложное
        // подозрение, — а стоит проверка столько же, сколько на длинной фразе.
        XCTAssertFalse(SecondOpinion.isSuspicious(confidence: -0.300, duration: 1.0))
    }

    func testMeasuredRangesLieOnOppositeSidesOfTheThreshold() {
        XCTAssertGreaterThan(Float(-0.001), SecondOpinion.suspicion, "чистый русский")
        XCTAssertLessThan(Float(-0.183), SecondOpinion.suspicion, "русский с украинской вставкой")
    }

    // MARK: - Кому отдавать кусок

    func testNeighbourTakesThePieceWhenTheStrongModelNamesIt() {
        // Замер: большая модель на этом куске сказала uk с уверенностью −0.107.
        XCTAssertTrue(SecondOpinion.belongsToNeighbour(
            verdict: "uk",
            confidence: -0.107,
            neighbour: .uk,
            reading: "Якщо вони натискали кнопку входу, не підтверджуйте."
        ))
    }

    func testOwnLanguageKeepsThePieceWhenTheStrongModelSaysSo() {
        XCTAssertFalse(SecondOpinion.belongsToNeighbour(
            verdict: "ru",
            confidence: -0.010,
            neighbour: .uk,
            reading: "Вот этот текст, если вы нажали кнопку входа, не подтверждайте."
        ))
    }

    func testUnsureVerdictDecidesNothing() {
        // Голый argmax уравнял бы «uk, −0.107» и «uk, −2.0». Второе — не ответ, а догадка
        // модели, которая речь толком не разобрала.
        XCTAssertFalse(SecondOpinion.belongsToNeighbour(
            verdict: "uk", confidence: -2.0, neighbour: .uk, reading: "Щось незрозуміле."
        ))
    }

    func testThirdLanguageVerdictChangesNothing() {
        // Определение языка иногда называет английский — это не повод отдавать кусок соседу.
        XCTAssertFalse(SecondOpinion.belongsToNeighbour(
            verdict: "en", confidence: -0.010, neighbour: .uk, reading: "Thanks."
        ))
    }

    func testEmptyReadingNeverReplacesAnything() {
        // Ловушка: большая модель на коротком отрезке молча возвращает пустоту, и вердикт
        // при этом остаётся уверенным. Менять живую речь на ничто нельзя.
        XCTAssertFalse(SecondOpinion.belongsToNeighbour(
            verdict: "uk", confidence: -0.010, neighbour: .uk, reading: ""
        ))
        XCTAssertFalse(SecondOpinion.belongsToNeighbour(
            verdict: "uk", confidence: -0.010, neighbour: .uk, reading: "   \n"
        ))
    }
}
