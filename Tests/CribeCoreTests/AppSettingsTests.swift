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

    /// Пропуск GPT на коротких диктовках включён по умолчанию, граница — 8 слов.
    func testShortDictationDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.skipGPTForShort)
        XCTAssertEqual(settings.shortDictationWordLimit, 8)
    }

    /// Выключённый тумблер и своя граница переживают перезапуск (дефолт у тумблера — `true`,
    /// поэтому `bool(forKey:)` не отличил бы «выключен» от «не задан»).
    func testShortDictationSettingsPersist() {
        let settings = AppSettings(defaults: defaults)
        settings.skipGPTForShort = false
        settings.shortDictationWordLimit = 3

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.skipGPTForShort)
        XCTAssertEqual(reloaded.shortDictationWordLimit, 3)
    }

    /// Возврат украинских вставок включён по умолчанию — владелец диктует по-русски с
    /// украинскими словами постоянно. Выключённый тумблер переживает перезапуск (дефолт
    /// `true`, поэтому `bool(forKey:)` не отличил бы «выключен» от «не задан»).
    func testRestoreUkrainianInsertsDefaultsOnAndPersists() {
        XCTAssertTrue(AppSettings(defaults: defaults).restoreUkrainianInserts)

        AppSettings(defaults: defaults).restoreUkrainianInserts = false
        XCTAssertFalse(AppSettings(defaults: defaults).restoreUkrainianInserts)
    }

    /// Карточки включены по умолчанию, а выключённый тумблер переживает перезапуск
    /// (дефолт `true`, поэтому `bool(forKey:)` не отличил бы «выключен» от «не задан»).
    func testCardsWhenNoFieldDefaultsOnAndPersists() {
        XCTAssertTrue(AppSettings(defaults: defaults).cardsWhenNoField)

        AppSettings(defaults: defaults).cardsWhenNoField = false
        XCTAssertFalse(AppSettings(defaults: defaults).cardsWhenNoField)
    }

    /// У перевода своя пара «модель + усилие» с собственными дефолтами.
    func testTranslateModelDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.translateModel, AppSettings.defaultTranslateModel)
        XCTAssertEqual(settings.translateEffort, AppSettings.defaultTranslateEffort)
    }

    /// Усилия у чистки и перевода свои и разные — общий дефолт `GPTConfig` (минимум, с
    /// которого начинает сам клиент) настройками приложения не переиспользуется.
    func testEffortDefaultsAreOwnedByAppSettings() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.gptEffort, "medium")
        XCTAssertEqual(settings.translateEffort, "high")
        XCTAssertEqual(AppSettings.defaultCleanupEffort, "medium")
        XCTAssertEqual(AppSettings.defaultTranslateEffort, "high")
    }

    func testTranslateModelSettingsPersist() {
        let settings = AppSettings(defaults: defaults)
        settings.translateModel = "gpt-5.6-sol"
        settings.translateEffort = "high"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.translateModel, "gpt-5.6-sol")
        XCTAssertEqual(reloaded.translateEffort, "high")
    }

    /// Конфигурация перевода берёт свою модель и своё усилие, но общий режим доступа —
    /// и при этом не задевает конфигурацию обычной чистки.
    func testTranslateGPTConfigIsSeparateFromCleanupConfig() {
        let settings = AppSettings(defaults: defaults)
        settings.gptMode = .apiKey
        settings.gptModel = "gpt-5.6-luna"
        settings.gptEffort = "none"
        settings.translateModel = "gpt-5.6-sol"
        settings.translateEffort = "medium"

        XCTAssertEqual(settings.translateGPTConfig.mode, .apiKey)
        XCTAssertEqual(settings.translateGPTConfig.model, "gpt-5.6-sol")
        XCTAssertEqual(settings.translateGPTConfig.effort, "medium")

        XCTAssertEqual(settings.gptConfig.model, "gpt-5.6-luna")
        XCTAssertEqual(settings.gptConfig.effort, "none")
    }

    /// Распознавание по умолчанию — быстрое: смена движка ничего не должна менять сама собой.
    func testRecognitionEngineDefaultsToFast() {
        XCTAssertEqual(AppSettings(defaults: defaults).recognitionEngine, .fast)
    }

    func testRecognitionEnginePersists() {
        AppSettings(defaults: defaults).recognitionEngine = .parakeet
        XCTAssertEqual(AppSettings(defaults: defaults).recognitionEngine, .parakeet)
    }

    /// Чужое значение в ключе не должно ронять запуск: непонятное читается как быстрое.
    func testUnknownRecognitionEngineFallsBackToFast() {
        defaults.set("nemotron", forKey: "recognitionEngine")
        XCTAssertEqual(AppSettings(defaults: defaults).recognitionEngine, .fast)
    }
}
