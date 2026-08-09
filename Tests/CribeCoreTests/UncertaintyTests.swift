import XCTest

@testable import CribeCore

/// Поиск сломанных кусков по уверенности. Все числа — из замера на двенадцати надиктованных
/// владельцем записях (2026-08-09), сверенного с тем, что человек на самом деле произнёс.
final class UncertaintyTests: XCTestCase {

    private func words(_ pairs: [(String, Float)]) -> [WordProbe] {
        pairs.map { WordProbe(word: $0.0, probability: $0.1) }
    }

    // MARK: - Склейка кусков в слова

    func testPiecesGlueIntoWordsBySpaces() {
        let probes = WordConfidence.words(from: [
            TokenProbe(text: " Пере", probability: 0.9),
            TokenProbe(text: "пиши", probability: 0.8),
            TokenProbe(text: " текст", probability: 0.99),
        ])
        XCTAssertEqual(probes.map(\.word), ["Перепиши", "текст"])
    }

    func testWordTakesTheConfidenceOfItsWeakestPiece() {
        // Слово собирается из двух-трёх кусков, и достаточно ошибиться в одном. Среднее
        // размыло бы ошибку ровно там, где её надо видеть.
        let probes = WordConfidence.words(from: [
            TokenProbe(text: " натыс", probability: 0.9),
            TokenProbe(text: "кали", probability: 0.311),
        ])
        XCTAssertEqual(probes.first?.probability, 0.311)
    }

    // MARK: - Молчание на верном тексте

    func testTechnicalDictationStaysSilent() {
        // «Задеплой на staging и проверь, что вебхук из Telegram доходит до бэкенда» —
        // распознано верно, но четыре слова поодиночке ниже порога: первое слово диктовки
        // и три термина, за которые словарная подсказка борется с кириллицей.
        let heard = words([
            ("Задеплой", 0.714), ("на", 0.976), ("staging", 0.434), ("и", 0.966),
            ("проверь,", 0.916), ("что", 0.994), ("вебхук", 0.662), ("из", 0.973),
            ("Telegram", 0.644), ("доходит", 0.987), ("до", 0.987), ("бэкэнда.", 0.817),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard), [])
    }

    func testNumbersAndUnitsStaySilent() {
        // «Нужно сократить время ответа с 300 мс до 120 мс» — верно целиком.
        let heard = words([
            ("Нужно", 0.702), ("сократить", 0.991), ("время", 0.991), ("ответа", 0.991),
            ("с", 0.968), ("300", 0.928), ("мс", 0.475), ("до", 0.839),
            ("120", 0.996), ("мс.", 0.590),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard), [])
    }

    func testTwoShakyWordsInARowAreNotEnough() {
        // «Напиши клієнту: «Вибачте, ми не встигли…» — текст верный, а два слова подряд
        // всё же просели: на стыке языков это законно.
        let heard = words([
            ("Напиши", 0.924), ("клієнту:", 0.594), ("«Вибачте,", 0.408), ("ми", 0.903),
            ("не", 0.997), ("встигли", 0.996),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard), [])
    }

    // MARK: - Крик на сломанном

    func testLostNegationIsCaught() {
        // Главный случай замера: человек сказал «Ваш платіж НЕ пройшов, перевірте дані
        // картки», а приехало «Ваш платежный пришёл в проверте данной картке».
        let heard = words([
            ("Заголовок", 0.925), ("такой:", 0.857), ("\"Ваш", 0.354), ("платежный", 0.661),
            ("пришёл", 0.338), ("в", 0.653), ("проверте", 0.583), ("данной", 0.698),
            ("картке\".", 0.580),
        ])
        let runs = Uncertainty.runs(in: heard)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.words.count, 7)
        XCTAssertEqual(runs.first?.text, "\"Ваш платежный пришёл в проверте данной картке\".")
    }

    func testThreeShakyWordsAreNoLongerEnough() {
        // «Оплата пройшла успешно» — настоящая поломка, но длиной ровно в три слова, и её
        // пришлось отдать: обе ложные тревоги живой диктовки были той же длины.
        let heard = words([
            ("таким:", 0.832), ("оплата", 0.685), ("пройшла", 0.655), ("успешно,", 0.480),
            ("спасибо", 0.964),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard), [])
    }

    // MARK: - Ложные тревоги живой диктовки (2026-08-09)

    func testShortDictationThatDippedEntirelyIsNotABreakage() {
        // «Да, уведомление видел» — три слова, все ниже порога. Цепочка совпала со всей
        // диктовкой: сравнивать не с чем, а значит и вывода нет.
        let heard = words([("Да,", 0.579), ("уведомление", 0.664), ("видел.", 0.514)])
        XCTAssertEqual(Uncertainty.runs(in: heard), [])
    }

    func testDoubtAboutPunctuationIsNotDoubtAboutWords() {
        // Диктовка длинная, уверенных слов полно, текст верный — а модель просела на трёх
        // словах подряд там, где решала, куда ставить кавычки и двоеточия. По самому числу
        // такое сомнение от сомнения в услышанном не отличить, поэтому спасает только длина.
        let heard = words([
            ("Даже", 0.936), ("вот", 0.867), ("сейчас,", 0.956), ("когда", 0.990), ("я", 0.965),
            ("написал:", 0.463), ("\"Да,", 0.580), ("уведомление", 0.830), ("видел\",", 0.353),
            ("показал:", 0.486), ("\"Сверьте,", 0.608), ("да,", 0.903), ("уведомление", 0.960),
            ("видел\".", 0.575), ("Хоть", 0.382), ("это", 0.989), ("и", 0.988),
            ("странно,", 0.930), ("конечно.", 0.796),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard), [])
    }

    func testOnlyLongEnoughBreakagesAreNamed() {
        // Украинская сессия с русской вставкой: сломаны и середина (пять слов), и хвост
        // (три). После ужесточения хвост уходит в пропуск — цена той же правки, что убрала
        // ложные тревоги.
        let heard = words([
            ("Давай", 0.810), ("перевіримо,", 0.739), ("як", 0.997), ("це", 0.993),
            ("працює.", 0.572), ("Він", 0.227), ("говорить,", 0.483), ("що", 0.646),
            ("не", 0.660), ("зможе", 0.596), ("приїхати", 0.827), ("раніше", 0.736),
            ("зі", 0.219), ("зору.", 0.121), ("Треба", 0.471), ("перенести", 0.938),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard).count, 1)
    }

    func testRunAtTheVeryEndIsNotLost() {
        let heard = words([
            ("Заголовок", 0.9), ("такой", 0.9),
            ("оплата", 0.4), ("пройшла", 0.4), ("успешно", 0.4), ("спосіб", 0.4),
        ])
        XCTAssertEqual(Uncertainty.runs(in: heard).count, 1)
    }

    func testNothingHeardMeansNothingToWarnAbout() {
        XCTAssertEqual(Uncertainty.runs(in: []), [])
    }

    // MARK: - Что говорим человеку

    func testNothingBrokenMeansNothingSaid() {
        XCTAssertNil(Uncertainty.alarm(runs: [], reread: []))
    }

    func testWarningNamesTheWordsToLookAt() {
        let runs = [UncertainRun(words: ["\"Ваш", "платежный", "пришёл"])]
        XCTAssertEqual(Uncertainty.alarm(runs: runs, reread: []), "сверьте: «\"Ваш платежный пришёл»")
    }

    func testRereadPhraseIsNamedInItsNewShape() {
        // Сверка соседним языком фразу переписала — старых слов в тексте нет, и называть
        // их значило бы отправить человека искать то, чего не осталось.
        let runs = [UncertainRun(words: ["\"Ваш", "платежный", "пришёл"])]
        XCTAssertEqual(
            Uncertainty.alarm(runs: runs, reread: ["Ваш платіж не пройшов"]),
            "сверьте: «Ваш платіж не пройшов»"
        )
    }

    func testSecondBrokenPlaceIsCountedNotQuoted() {
        // Капсула маленькая: второй адрес в неё не влезет, а число подскажет, что смотреть
        // надо не только сюда.
        let runs = [UncertainRun(words: ["раз", "два", "три"]), UncertainRun(words: ["a", "b", "c"])]
        XCTAssertEqual(Uncertainty.alarm(runs: runs, reread: []), "сверьте: «раз два три» и ещё 1")
    }

    func testLongQuoteIsCutSoThePillStaysSmall() {
        let long = UncertainRun(words: Array(repeating: "слово", count: 20))
        let alarm = Uncertainty.alarm(runs: [long], reread: []) ?? ""
        XCTAssertTrue(alarm.hasSuffix("…»"), "длинный кусок обрезается: \(alarm)")
        XCTAssertLessThan(alarm.count, Uncertainty.quotedLimit + 15)
    }

    func testMeasuredBoundaryLiesBetweenTheWorstCorrectAndTheBestBrokenRun() {
        // Все настоящие поломки замера были длиной 4, 5 и 7 слов, обе ложные тревоги
        // живой диктовки — ровно 3. Порог стоит между ними.
        XCTAssertEqual(Uncertainty.minimumLength, 4)
        XCTAssertLessThan(Float(0.408), Uncertainty.shaky, "худшее слово верной пары")
    }
}
