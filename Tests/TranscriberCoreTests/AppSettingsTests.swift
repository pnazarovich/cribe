import XCTest
@testable import TranscriberCore

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
}
