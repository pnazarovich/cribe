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

    /// Смешанная речь ожидается по умолчанию: приложение делают двуязычные люди для
    /// двуязычных. Выключённый тумблер переживает перезапуск (дефолт `true`, поэтому
    /// `bool(forKey:)` не отличил бы «выключен» от «не задан»).
    func testMixesUkrainianDefaultsOnAndPersists() {
        XCTAssertTrue(AppSettings(defaults: defaults).mixesUkrainian)

        AppSettings(defaults: defaults).mixesUkrainian = false
        XCTAssertFalse(AppSettings(defaults: defaults).mixesUkrainian)
    }

    /// Галочка собрана из двух прежних, и выбор человека обязан её пережить: тот, кто
    /// выключил возврат украинских вставок, не должен получить его обратно обновлением.
    func testMixesUkrainianInheritsTheOldKey() {
        defaults.set(false, forKey: "restoreUkrainianInserts")
        XCTAssertFalse(AppSettings(defaults: defaults).mixesUkrainian)
    }

    /// Своё значение сильнее унаследованного: человек мог передумать уже в новой версии.
    func testOwnKeyWinsOverTheOldOne() {
        defaults.set(false, forKey: "restoreUkrainianInserts")
        defaults.set(true, forKey: "mixesUkrainian")
        XCTAssertTrue(AppSettings(defaults: defaults).mixesUkrainian)
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
    /// против 2,82 с у `medium`), а переводу оставлен `high` — цена ошибки там выше.
    func testCleanupAndTranslateShareModelButNotEffort() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.gptConfig.model, GPTConfig.defaultModel)
        XCTAssertEqual(settings.translateGPTConfig.model, GPTConfig.defaultModel)
        XCTAssertEqual(settings.gptConfig.effort, "low")
        XCTAssertEqual(settings.translateGPTConfig.effort, "high")
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
