import XCTest
@testable import Cribe
@testable import CribeCore

/// Логика редактора словаря, которую видно только на числах: слияние дублей, порядок
/// записи и отложенное сохранение. Всё это статические функции — без окон и без SwiftUI.
@MainActor
final class DictionaryEditorLogicTests: XCTestCase {
    private typealias Model = DictionaryEditorModel
    private typealias Term = DictionaryEditorModel.Term

    private let github = Term(canonical: "GitHub", variants: ["гитхаб"])
    private let deploy = Term(canonical: "deploy", variants: ["деплой"])

    // MARK: - Слияние дублей

    /// Новый термин встаёт первым: «недавно добавленное сверху» видно сразу, а не
    /// после следующего открытия окна.
    func testNewTermGoesToTheTop() {
        let result = Model.merging([github, deploy], canonical: "Docker", variants: ["докер"], stem: true)
        XCTAssertFalse(result.merged)
        XCTAssertEqual(result.terms.map(\.canonical), ["Docker", "GitHub", "deploy"])
        XCTAssertEqual(result.terms[0].variants, ["докер"])
    }

    /// Второй карточки на тот же термин быть не может: два правила на один термин
    /// ведут себя непредсказуемо — варианты вливаются в существующую.
    func testDuplicateCanonicalMergesInsteadOfAddingCard() {
        let result = Model.merging([github, deploy], canonical: "github", variants: ["гит хаб"], stem: true)
        XCTAssertTrue(result.merged)
        XCTAssertEqual(result.terms.count, 2)
        XCTAssertEqual(result.terms[0].variants, ["гитхаб", "гит хаб"])
        XCTAssertEqual(result.terms[0].id, github.id, "карточка та же самая")
        XCTAssertEqual(result.terms[0].note, "варианты добавлены к существующему термину")
    }

    /// Слияние без новых вариантов — тоже слияние, но об этом надо сказать иначе:
    /// иначе непонятно, почему ничего не произошло.
    func testDuplicateWithoutNewVariantsSaysSo() {
        let result = Model.merging([github], canonical: "GitHub", variants: ["ГИТХАБ"], stem: true)
        XCTAssertTrue(result.merged)
        XCTAssertEqual(result.terms[0].variants, ["гитхаб"])
        XCTAssertEqual(result.terms[0].note, "такой термин уже есть")
    }

    func testAppendingKeepsOrderAndDropsDuplicates() {
        let result = Model.appending(["ГИТ ХАБ", "гитхаб", "  ", "гіт хаб"], to: ["гитхаб"])
        XCTAssertEqual(result, ["гитхаб", "гит хаб", "гіт хаб"])
    }

    // MARK: - Порядок и формат записи

    func testEntriesPutRecentlyEditedFirst() {
        let terms = [github, deploy, Term(canonical: "Docker", variants: [])]
        let entries = Model.entries(from: terms, touched: [terms[2].id, deploy.id])
        XCTAssertEqual(entries.map(\.canonical), ["Docker", "deploy", "GitHub"])
    }

    /// Идентификаторы обязаны дожить до файла: словарь на диске живой, и подмена id
    /// на каждой правке переписывала бы его целиком.
    func testEntriesKeepIdentifiersAndFields() {
        let entries = Model.entries(from: [github], touched: [])
        XCTAssertEqual(entries, [DictionaryEntry(id: github.id, canonical: "GitHub", variants: ["гитхаб"], stem: true)])
    }

    func testEntriesDropTermsWithoutCanonicalAndTrimIt() {
        let terms = [Term(canonical: "  Docker  ", variants: []), Term(canonical: "   ", variants: ["что-то"])]
        let entries = Model.entries(from: terms, touched: [])
        XCTAssertEqual(entries.map(\.canonical), ["Docker"])
    }

    // MARK: - Поиск и слова диктовки

    func testSearchLooksAtBothCanonicalAndVariants() {
        let terms = [github, deploy]
        XCTAssertEqual(Model.filtered(terms, search: "hub").map(\.canonical), ["GitHub"])
        XCTAssertEqual(Model.filtered(terms, search: "деплой").map(\.canonical), ["deploy"])
        XCTAssertEqual(Model.filtered(terms, search: "  ").count, 2)
        XCTAssertTrue(Model.filtered(terms, search: "кубер").isEmpty)
    }

    /// Слова из диктовки: без пунктуации, без повторов, без известного словарю
    /// и без коротышей («в», «и») — терминами они не бывают.
    func testDictationWordsSkipKnownShortAndRepeated() {
        let words = Model.words(
            in: "Залил в гитхаб, потом снова гитхаб и кубер!",
            known: ["гитхаб"]
        )
        XCTAssertEqual(words, ["залил", "потом", "снова", "кубер"])
    }

    // MARK: - Автосохранение

    /// Пользователь печатает вариант посимвольно — на диск это обязано уехать один раз.
    func testDebounceRunsOnceAfterTheLastEdit() async throws {
        let debounce = Debounce(delay: .milliseconds(80))
        let counter = Counter()

        debounce.schedule { counter.value += 1 }
        debounce.schedule { counter.value += 1 }
        debounce.schedule { counter.value += 1 }
        XCTAssertEqual(counter.value, 0, "до паузы на диск не пишем")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.value, 1)
    }

    /// Окно закрывают, не дожидаясь таймера: недописанное дописываем немедленно.
    func testFlushWritesPendingImmediately() {
        let debounce = Debounce(delay: .seconds(30))
        let counter = Counter()

        debounce.schedule { counter.value += 1 }
        XCTAssertTrue(debounce.isPending)
        debounce.flush()

        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(debounce.isPending)
        debounce.flush()
        XCTAssertEqual(counter.value, 1, "второй flush выполнять уже нечего")
    }
}

@MainActor
private final class Counter {
    var value = 0
}
