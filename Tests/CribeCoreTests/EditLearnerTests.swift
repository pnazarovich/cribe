import XCTest
@testable import CribeCore

/// Накопитель правок. Главное свойство здесь — сдержанность: в словарь попадает только то,
/// что человек исправил дважды. Ошибка в эту сторону дешёвая (подсказка не появилась),
/// в обратную — дорогая: мусорная статья портит каждую следующую диктовку.
final class EditLearnerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Своя область: прогон не имеет права трогать настройки пользователя.
        defaults = UserDefaults(suiteName: "cribe.tests.\(UUID().uuidString)")
    }

    private func learner() -> EditLearner { EditLearner(defaults: defaults) }

    private let fix = Correction(heard: "хероблок", meant: "heroblock")

    /// Одна правка — это ещё не термин. Человек мог исправить что угодно и почему угодно.
    func testSingleCorrectionDoesNotReachTheDictionary() {
        let learned = learner().observe([fix], entries: [])
        XCTAssertEqual(learned, [])
    }

    /// Та же правка во второй раз — уже про то, как человек говорит.
    func testRepeatedCorrectionBecomesAnEntry() {
        let subject = learner()
        _ = subject.observe([fix], entries: [])
        let learned = subject.observe([fix], entries: [])

        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.canonical, "heroblock")
        XCTAssertEqual(learned.first?.variants, ["хероблок"])
    }

    /// Счётчики переживают перезапуск: иначе порог не набрался бы никогда — человек
    /// правит одно и то же слово в разные дни.
    func testCountsSurviveRestart() {
        _ = learner().observe([fix], entries: [])
        // Новый экземпляр — как после перезапуска приложения.
        let learned = learner().observe([fix], entries: [])
        XCTAssertEqual(learned.count, 1)
    }

    /// Порог набран — счётчик обнуляется, и та же правка не приносит статью снова.
    func testEntryIsNotLearnedTwice() {
        let subject = learner()
        _ = subject.observe([fix], entries: [])
        let entries = subject.observe([fix], entries: [])
        XCTAssertEqual(subject.observe([fix], entries: entries), [])
    }

    /// Слово уже есть в словаре вариантом: замена и так произойдёт сама, а правка была
    /// про что-то другое — например, человек передумал и написал иначе.
    func testKnownVariantIsNotCounted() {
        let entries = [DictionaryEntry(canonical: "heroblock", variants: ["хероблок"])]
        let subject = learner()
        _ = subject.observe([fix], entries: entries)
        XCTAssertEqual(subject.observe([fix], entries: entries), [])
    }

    /// Каноническая форма уже в словаре, а такого варианта у неё нет: вариант дописывается
    /// в существующую статью, а не заводит вторую про то же слово.
    func testVariantJoinsAnExistingEntry() {
        let existing = DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])
        let subject = learner()
        let correction = Correction(heard: "гит хаб", meant: "GitHub")
        _ = subject.observe([correction], entries: [existing])
        let learned = subject.observe([correction], entries: [existing])

        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.id, existing.id, "статья должна быть той же, а не новой")
        XCTAssertEqual(learned.first?.variants, ["гитхаб", "гит хаб"])
    }

    /// Отклонённая правка не считается больше никогда.
    func testIgnoredCorrectionNeverReturns() {
        let subject = learner()
        subject.ignore(fix)
        _ = subject.observe([fix], entries: [])
        XCTAssertEqual(subject.observe([fix], entries: []), [])
        XCTAssertTrue(subject.pending.isEmpty)
    }

    /// Правку можно принять сразу, не дожидаясь повтора.
    func testCorrectionCanBeAcceptedEarly() {
        let subject = learner()
        _ = subject.observe([fix], entries: [])
        let entry = subject.accept(fix, entries: [])

        XCTAssertEqual(entry.canonical, "heroblock")
        XCTAssertTrue(subject.pending.isEmpty, "принятая правка не висит в ожидании")
    }

    /// Одиночные правки видны человеку — это и есть замена прежним «Предложениям».
    func testPendingListsWhatWasNoticedOnce() {
        let subject = learner()
        _ = subject.observe([fix], entries: [])
        XCTAssertEqual(subject.pending.map(\.correction), [fix])
        XCTAssertEqual(subject.pending.first?.count, 1)
    }
}
