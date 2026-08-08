import XCTest

@testable import CribeCore

/// Правило второго мнения. Все числа — из замера на двенадцати надиктованных владельцем
/// записях (2026-08-08, восемнадцать кусков речи). Синтетическая речь для этой задачи
/// негодна: на ней фича дважды «чинилась» ложно (см. коммит 441156a).
final class SecondOpinionTests: XCTestCase {

    // MARK: - Кого спрашивать

    func testRussianAsksUkrainian() {
        XCTAssertEqual(Language.ru.neighbour, .uk)
    }

    func testEnglishHasNoNeighbour() {
        XCTAssertNil(Language.en.neighbour, "с английским такой беды не наблюдалось")
    }

    func testUkrainianAsksRussian() {
        // Обратное направление держали выключенным из общего соображения «turbo слабее
        // large-v3, значит судья из неё плохой». Замер на двух украинских диктовках
        // владельца с русской вставкой (2026-08-09) это опроверг: обе без второго мнения
        // ломались («зі зору» вместо «среды», «спосіб» вместо «спасибо»), обе со вторым
        // мнением вернулись дословно верными.
        XCTAssertEqual(Language.uk.neighbour, .ru)
    }

    // MARK: - Кого проверять

    func testConfidentlyOwnPiecesAreNotDoubted() {
        // Все чисто русские куски замера: определитель называет их русскими безоговорочно.
        for confidence in [Float(-0.000), -0.001, -0.002, -0.003] {
            XCTAssertFalse(
                SecondOpinion.isSuspicious(
                    detected: "ru", confidence: confidence, own: .ru, duration: 5.5
                ),
                "уверенность \(confidence) — это чистый свой язык, второе мнение стоит времени"
            )
        }
    }

    func testForeignVerdictIsEnoughEvenWhenConfident() {
        // Главная поправка после замера. Определитель вовсе не обязан сомневаться на чужой
        // речи: на трёх записях он уверенно и ПРАВИЛЬНО называл украинский. Прежнее правило
        // «спрашиваем, только когда он не уверен» эти куски молча пропускало.
        for confidence in [Float(-0.006), -0.007, -0.010] {
            XCTAssertTrue(
                SecondOpinion.isSuspicious(
                    detected: "uk", confidence: confidence, own: .ru, duration: 5.5
                ),
                "определитель прямо назвал соседа — этого достаточно"
            )
        }
    }

    func testUnsureOwnVerdictIsAlsoEnough() {
        // Русское начало переходит в украинскую вставку: определитель отвечает «русский»,
        // но плохо. Три таких куска в замере.
        for confidence in [Float(-0.183), -0.556, -1.346] {
            XCTAssertTrue(SecondOpinion.isSuspicious(
                detected: "ru", confidence: confidence, own: .ru, duration: 4.9
            ))
        }
    }

    func testShortPiecesAreLeftAlone() {
        // «Пока.» длиной в секунду: определение соврало (en, −0.300) — то есть дало ложное
        // подозрение, — а стоит проверка столько же, сколько на длинной фразе.
        XCTAssertFalse(SecondOpinion.isSuspicious(
            detected: "en", confidence: -0.300, own: .ru, duration: 1.0
        ))
    }

    func testMeasuredRangesLieOnOppositeSidesOfTheThreshold() {
        XCTAssertGreaterThan(Float(-0.003), SecondOpinion.certainty, "худший чистый русский")
        XCTAssertLessThan(Float(-0.183), SecondOpinion.certainty, "лучший подозрительный")
    }

    // MARK: - Право вето у модели соседа

    func testStrongModelKeepsThePieceOnlyWhenSureItIsOurs() {
        // На чистых кусках она говорит «русский» с −0.002…−0.007.
        for confidence in [Float(-0.002), -0.004, -0.007] {
            XCTAssertTrue(SecondOpinion.keepsOwn(verdict: "ru", confidence: confidence, own: .ru))
        }
    }

    func testUnsureOwnVerdictDoesNotVeto() {
        // Тот самый случай, на котором проваливается голосование: сильная модель называет
        // «русский» (−0.399), хотя по-украински читает кусок почти дословно верно.
        // Сомнение в её ответе — не довод оставить кусок как есть.
        XCTAssertFalse(SecondOpinion.keepsOwn(verdict: "ru", confidence: -0.399, own: .ru))
    }

    func testForeignVerdictNeverVetoes() {
        for confidence in [Float(-0.067), -0.107, -0.253] {
            XCTAssertFalse(SecondOpinion.keepsOwn(verdict: "uk", confidence: confidence, own: .ru))
        }
    }

    // MARK: - Чем заменять

    func testEmptyReadingIsNotAnAnswer() {
        // Большая модель на коротком отрезке молча отдаёт пустоту. Менять на неё живую
        // речь нельзя ни при каком вердикте.
        XCTAssertFalse(SecondOpinion.usable(""))
        XCTAssertFalse(SecondOpinion.usable("   \n"))
        XCTAssertTrue(SecondOpinion.usable("Якщо ви не натискали кнопку входу, не підтверджуйте."))
    }
}
