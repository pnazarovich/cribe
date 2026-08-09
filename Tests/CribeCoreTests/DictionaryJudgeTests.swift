import XCTest

@testable import CribeCore

/// Судья словаря. Сеть здесь не участвует: проверяется, что он видит, как разбирается его
/// ответ и что из предложенного вообще имеет право дойти до словаря.
final class DictionaryJudgeTests: XCTestCase {

    private func observation(
        dictated: String = "поправим хероблок сегодня",
        recognized: String? = nil,
        baseline: String? = nil,
        final: String = "поправим heroblock сегодня",
        changes: [FieldChange] = [],
        corrections: [(String, String, TimeInterval)] = []
    ) -> FieldObservation {
        FieldObservation(
            dictated: dictated,
            recognized: recognized ?? dictated,
            baseline: baseline ?? dictated,
            final: final,
            changes: changes,
            corrections: corrections.map {
                ObservedCorrection(correction: Correction(heard: $0.0, meant: $0.1), after: $0.2)
            }
        )
    }

    // MARK: - Разбор ответа

    func testProposalIsReadWithItsReason() {
        let pairs = DictionaryJudge.parse("ДА|хероблок|heroblock|название продукта на слух")
        XCTAssertEqual(
            pairs,
            [DictionaryJudge.Proposal(heard: "хероблок", meant: "heroblock", reason: "название продукта на слух")]
        )
    }

    func testEveryLineIsItsOwnProposal() {
        let answer = """
            ДА|хероблок|heroblock|продукт
            ДА|гит хаб|GitHub|бренд
            """
        XCTAssertEqual(DictionaryJudge.parse(answer).map(\.meant), ["heroblock", "GitHub"])
    }

    func testRefusalProposesNothing() {
        XCTAssertEqual(DictionaryJudge.parse("НЕТ|человек переписал фразу"), [])
    }

    func testUnparseableAnswerProposesNothing() {
        // Сбой формата не имеет права ничего предлагать: лишняя пара в словаре молча портит
        // ВСЕ будущие диктовки, а пропущенную человек добавит сам.
        for answer in ["", "не уверен", "{\"add\": true}", "ДА", "ДА|хероблок", "yes|a|b"] {
            XCTAssertEqual(
                DictionaryJudge.parse(answer), [],
                "неразобранный ответ «\(answer)» не имеет права ничего предлагать"
            )
        }
    }

    func testCaseAndSpacesDoNotChangeTheProposal() {
        XCTAssertEqual(DictionaryJudge.parse(" да | хероблок | heroblock | продукт ").count, 1)
    }

    // MARK: - Что вообще имеет право дойти до словаря

    func testProposalMustBeConfirmedByBothTexts() {
        let seen = observation()
        let good = DictionaryJudge.Proposal(heard: "хероблок", meant: "heroblock", reason: "")
        XCTAssertEqual(
            DictionaryJudge.confirmed([good], in: seen),
            [Correction(heard: "хероблок", meant: "heroblock")]
        )
    }

    func testInventedWordIsDropped() {
        // Модель вольна в словах, а словарь — нет: пары, которой в текстах нет, не было.
        let seen = observation()
        let invented = DictionaryJudge.Proposal(heard: "гиперблок", meant: "heroblock", reason: "")
        let unwritten = DictionaryJudge.Proposal(heard: "хероблок", meant: "HeroBlocks", reason: "")
        XCTAssertEqual(DictionaryJudge.confirmed([invented, unwritten], in: seen), [])
    }

    /// Живой случай, ради которого судья вообще видит два текста. Распознавание услышало
    /// «клайв», причёсывание превратило это в «scribe», человек исправил на «Cribe».
    /// Словарь применяется ДО причёсывания — значит, годится только слово распознавания;
    /// пара «scribe → Cribe» не сработала бы ни разу.
    func testPairFromTheRecognizedTextIsAccepted() {
        let seen = observation(
            dictated: "открой scribe сегодня",
            recognized: "открой клайв сегодня",
            final: "открой Cribe сегодня"
        )
        let right = DictionaryJudge.Proposal(heard: "клайв", meant: "Cribe", reason: "услышано на слух")
        XCTAssertEqual(
            DictionaryJudge.confirmed([right], in: seen),
            [Correction(heard: "клайв", meant: "Cribe")]
        )
    }

    /// Оба текста наши, и оба годятся источником: когда причёсывание слова не тронуло,
    /// они совпадают, и отсечь причёсанное значило бы отсечь заодно верную пару.
    func testPairFromTheInsertedTextIsStillAllowed() {
        let seen = observation(
            dictated: "открой scribe сегодня",
            recognized: "открой клайв сегодня",
            final: "открой Cribe сегодня"
        )
        let tidied = DictionaryJudge.Proposal(heard: "scribe", meant: "Cribe", reason: "")
        XCTAssertEqual(DictionaryJudge.confirmed([tidied], in: seen).count, 1)
    }

    func testJudgeSeesBothTextsApart() {
        let input = DictionaryJudge.input(
            observation(dictated: "открой scribe", recognized: "открой клайв"),
            language: .ru
        )
        XCTAssertTrue(input.contains("Распознавание услышало:\nоткрой клайв"))
        XCTAssertTrue(input.contains("После причёсывания в поле вставлено:\nоткрой scribe"))
    }

    func testPromptNamesWhichHalfOfThePairIsWhich() {
        // Без этого правила модель возьмёт слово из вставленного текста — оно ближе к правке.
        XCTAssertTrue(DictionaryJudge.systemPrompt.contains("ИЗ УСЛЫШАННОГО"))
    }

    func testImplausiblePairIsDropped() {
        // Смена регистра — не термин: приложение вставило слово верно.
        let seen = observation(dictated: "привет мир", final: "Привет мир")
        let cased = DictionaryJudge.Proposal(heard: "привет", meant: "Привет", reason: "")
        XCTAssertEqual(DictionaryJudge.confirmed([cased], in: seen), [])
    }

    func testOneWordGetsOneAnswer() {
        // Две трактовки одного и того же слова — это спор, а не два урока.
        let seen = observation(final: "поправим heroblock hero сегодня")
        let first = DictionaryJudge.Proposal(heard: "хероблок", meant: "heroblock", reason: "")
        let second = DictionaryJudge.Proposal(heard: "хероблок", meant: "hero", reason: "")
        XCTAssertEqual(DictionaryJudge.confirmed([first, second], in: seen).count, 1)
    }

    // MARK: - Что видит судья

    func testJudgeSeesTheWholePicture() {
        let seen = observation(
            baseline: "заметка: поправим хероблок сегодня",
            final: "заметка: поправим heroblock сегодня и завтра",
            changes: [
                FieldChange(after: 4, blocks: [EditBlock(removed: ["хероблок"], added: ["heroblock"])]),
                FieldChange(after: 12, blocks: [EditBlock(removed: [], added: ["и", "завтра"])]),
            ],
            corrections: [("хероблок", "heroblock", 4)]
        )
        let input = DictionaryJudge.input(seen, language: .ru)

        XCTAssertTrue(input.contains("поправим хероблок сегодня"), "вставленный текст")
        XCTAssertTrue(input.contains("заметка: поправим хероблок сегодня"), "поле целиком, а не только наше")
        XCTAssertTrue(input.contains("заметка: поправим heroblock сегодня и завтра"), "и чем всё кончилось")
        XCTAssertTrue(input.contains("через 4 с: «хероблок» → «heroblock»"))
        XCTAssertTrue(input.contains("через 12 с: добавлено «и завтра»"))
        XCTAssertTrue(input.contains("Русский"), "язык диктовки — тоже довод")
    }

    func testTimelineNamesWhatHappened() {
        let line = DictionaryJudge.timeline([
            FieldChange(after: 2, blocks: [EditBlock(removed: ["слово"], added: ["другое"])]),
            FieldChange(after: 6, blocks: [EditBlock(removed: [], added: ["хвост"])]),
            FieldChange(after: 8, blocks: [EditBlock(removed: ["лишнее"], added: [])]),
        ])
        XCTAssertEqual(
            line,
            """
            через 2 с: «слово» → «другое»
            через 6 с: добавлено «хвост»
            через 8 с: удалено «лишнее»
            """
        )
    }

    func testCandidatesAreOfferedAsAHintNotALimit() {
        let input = DictionaryJudge.input(observation(corrections: [("хероблок", "heroblock", 4)]), language: .ru)
        XCTAssertTrue(input.contains("могут быть не все"))
    }

    func testPromptExplainsWhyTimingMatters() {
        // Время — довод: правят сразу, а работать поверх начинают потом.
        XCTAssertTrue(DictionaryJudge.systemPrompt.contains("Время — довод"))
    }

    func testPromptForbidsProposingOnDoubt() {
        // Правило, ради которого судья и заведён: цена ошибки несимметрична.
        XCTAssertTrue(DictionaryJudge.systemPrompt.contains("Сомневаешься"))
    }
}

/// Что человек увидит на плашке: пара для словаря берётся из услышанного, а слово,
/// которое он правил своими руками, — из вставленного текста.
@MainActor
final class LearnRequestTests: XCTestCase {

    private func observation(dictated: String, recognized: String, final: String, pairs: [(String, String)])
        -> FieldObservation {
        FieldObservation(
            dictated: dictated,
            recognized: recognized,
            baseline: dictated,
            final: final,
            changes: [],
            corrections: pairs.map {
                ObservedCorrection(correction: Correction(heard: $0.0, meant: $0.1), after: 4)
            }
        )
    }

    /// Живой случай: услышано «клайв», вставлено «scribe», исправлено на «Cribe».
    func testEditedWordIsTheOneThePersonSaw() {
        let seen = observation(
            dictated: "открой scribe сегодня",
            recognized: "открой клайв сегодня",
            final: "открой Cribe сегодня",
            pairs: [("scribe", "Cribe")]
        )
        XCTAssertEqual(
            DictationController.edited(Correction(heard: "клайв", meant: "Cribe"), in: seen),
            "scribe"
        )
    }

    /// Причёсывание слова не тронуло: объяснять нечего, и второе слово не называем.
    func testNothingToExplainWhenTheWordsMatch() {
        let seen = observation(
            dictated: "открой клайв сегодня",
            recognized: "открой клайв сегодня",
            final: "открой Cribe сегодня",
            pairs: [("клайв", "Cribe")]
        )
        XCTAssertNil(DictationController.edited(Correction(heard: "клайв", meant: "Cribe"), in: seen))
    }

    /// Ради этого случая слово и ищется сличением наших текстов, а не разбором поля.
    /// Разбор здесь молчит: человек поправил слово и тут же печатал рядом, два изменения
    /// слились в один блок. Показать всё равно обязаны то, что стояло на экране.
    func testEditedWordIsFoundEvenWhenTheFieldDiffIsSilent() {
        let seen = observation(
            dictated: "открой scribe сегодня",
            recognized: "открой клайв сегодня",
            final: "открой Cribe завтра",
            pairs: []
        )
        XCTAssertEqual(
            DictationController.edited(Correction(heard: "клайв", meant: "Cribe"), in: seen),
            "scribe"
        )
    }

    /// Причёсывание переписало полфразы: какое слово встало на место услышанного, сказать
    /// нечем. Молчание здесь честнее догадки — плашка назовёт то, что знает.
    func testWholesaleRewriteLeavesNothingToShow() {
        let seen = observation(
            dictated: "давай откроем scribe прямо сейчас",
            recognized: "открой клайв сегодня",
            final: "давай откроем Cribe прямо сейчас",
            pairs: []
        )
        XCTAssertNil(DictationController.edited(Correction(heard: "клайв", meant: "Cribe"), in: seen))
    }
}
