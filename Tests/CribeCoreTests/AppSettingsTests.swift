import XCTest
@testable import CribeCore

final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Автостоп по тишине выключен, пока его явно не включили: запись должна
    /// останавливаться только повторным нажатием хоткея.
    func testAutoStopIsOffByDefault() {
        XCTAssertFalse(AppSettings(defaults: defaults).autoStopEnabled)
    }

    /// Включённый автостоп переживает перезапуск: значение пишется в UserDefaults,
    /// а не живёт только в памяти (`bool(forKey:)` не отличил бы «выключен» от «не задан»).
    func testAutoStopPersists() {
        AppSettings(defaults: defaults).autoStopEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).autoStopEnabled)
    }

    /// Учёба на правках включена по умолчанию: без неё словарь пополняется только руками,
    /// а выключить её человек может и в онбординге, и в настройках.
    func testLearningFromEditsIsOnByDefault() {
        XCTAssertTrue(AppSettings(defaults: defaults).learnsFromEdits)
    }

    /// Отказ обязан пережить перезапуск: дефолт здесь `true`, и `bool(forKey:)` не отличил
    /// бы «выключено» от «не задано».
    func testLearningFromEditsPersists() {
        AppSettings(defaults: defaults).learnsFromEdits = false
        XCTAssertFalse(AppSettings(defaults: defaults).learnsFromEdits)
    }

    // MARK: - Набор языков

    /// Прежние «русский + галочка “мешаю”» (а галочка стояла по умолчанию) — это ровно
    /// «русский и украинский». У обновившегося чистка ведёт себя точно как раньше.
    func testLanguagesMigrateFromSingleLanguageAndMixing() {
        defaults.set("ru", forKey: "language")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.ru, .uk], "галочка по умолчанию стояла")

        defaults.set(false, forKey: "mixesUkrainian")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.ru])

        defaults.set("uk", forKey: "language")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.uk])

        // Украинский с галочкой — всё равно один украинский: на украинскую чистку галочка
        // не влияла, а «оба» сделали бы основным русский.
        defaults.set(true, forKey: "mixesUkrainian")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.uk])

        defaults.set("en", forKey: "language")
        defaults.set(true, forKey: "mixesUkrainian")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.en], "английскому мешать не с чем")
    }

    /// Ещё более старый ключ той же галочки тоже переносится.
    func testLegacyMixingKeyStillMigrates() {
        defaults.set("ru", forKey: "language")
        defaults.set(false, forKey: "restoreUkrainianInserts")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.ru])
    }

    /// Новичку — русский с украинским, как и прежнее умолчание.
    func testDefaultLanguagesForNewcomers() {
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.ru, .uk])
    }

    func testLanguagesPersist() {
        let settings = AppSettings(defaults: defaults)
        settings.set(.en, enabled: true)
        settings.set(.uk, enabled: false)
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.ru, .en])
    }

    /// Последний флажок не снимается: без языка диктовать не на чем.
    func testLastLanguageCannotBeUnchecked() {
        let settings = AppSettings(defaults: defaults)
        settings.language = .uk
        settings.set(.uk, enabled: false)
        XCTAssertEqual(settings.languages, [.uk])
    }

    /// Смешанная речь — это два отмеченных флажка, а не отдельная галочка.
    func testMixingIsBothFlags() {
        let settings = AppSettings(defaults: defaults)
        settings.language = .ru
        XCTAssertFalse(settings.mixesUkrainian)
        settings.set(.uk, enabled: true)
        XCTAssertTrue(settings.mixesUkrainian)
    }

    /// Своё значение прежней галочки сильнее самого старого ключа: человек мог передумать
    /// уже в версии с одной галочкой.
    func testOwnMixingKeyWinsOverTheOldestOne() {
        defaults.set("ru", forKey: "language")
        defaults.set(false, forKey: "restoreUkrainianInserts")
        defaults.set(true, forKey: "mixesUkrainian")
        XCTAssertEqual(AppSettings(defaults: defaults).languages, [.ru, .uk])
    }

    /// Карточки включены по умолчанию, а выключённый тумблер переживает перезапуск
    /// (дефолт `true`, поэтому `bool(forKey:)` не отличил бы «выключен» от «не задан»).
    func testCardsWhenNoFieldDefaultsOnAndPersists() {
        XCTAssertTrue(AppSettings(defaults: defaults).cardsWhenNoField)

        AppSettings(defaults: defaults).cardsWhenNoField = false
        XCTAssertFalse(AppSettings(defaults: defaults).cardsWhenNoField)
    }

    /// Модель человек не выбирает — она одна и у чистки, и у перевода. Отличаются они
    /// усилием: замер показал, что чистке хватает `low` (те же 51/51 при медиане 2,48 с
    /// против 2,82 с у `medium`), а переводу — `medium`: выше, чем чистке, потому что цена ошибки там выше, но не
    /// `high` — на `gpt-6-sol` он вдвое медленнее без выигрыша в переводе (замер 2026-10-18).
    func testCleanupAndTranslateShareModelButNotEffort() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.gptConfig.model, GPTConfig.defaultModel)
        XCTAssertEqual(settings.translateGPTConfig.model, GPTConfig.defaultModel)
        XCTAssertEqual(settings.gptConfig.effort, "low")
        XCTAssertEqual(settings.translateGPTConfig.effort, "medium")
    }

    /// Режим доступа общий: вход в ChatGPT один, и перевод не ходит мимо него.
    func testTranslateConfigSharesTheAccessMode() {
        let settings = AppSettings(defaults: defaults)
        settings.gptMode = .apiKey
        XCTAssertEqual(settings.translateGPTConfig.mode, .apiKey)
        XCTAssertEqual(settings.gptConfig.mode, .apiKey)
    }

    /// Язык перевода по умолчанию — английский: у тех, кто обновится, правый ⌥ продолжит
    /// работать ровно так же, как работал.
    func testTranslationTargetDefaultsToEnglish() {
        XCTAssertEqual(AppSettings(defaults: defaults).translationTarget, TranslationTarget.en)
    }

    /// И переживает перезапуск: иначе выбор языка пришлось бы делать каждый раз заново.
    func testTranslationTargetPersists() {
        AppSettings(defaults: defaults).translationTarget = .pl
        XCTAssertEqual(AppSettings(defaults: defaults).translationTarget, TranslationTarget.pl)
    }
}
