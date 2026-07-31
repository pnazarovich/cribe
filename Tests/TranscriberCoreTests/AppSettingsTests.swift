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
}
