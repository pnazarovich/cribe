import XCTest
@testable import CribeCore

/// Какой движок распознаёт (GitHub #4). GigaAM знает только русский и пишет английские
/// названия кириллицей, поэтому берётся лишь там, где он точно не хуже Parakeet.
final class RecognitionRouterTests: XCTestCase {

    private func router(engine: RecognitionEngineChoice, languages: [Language], installed: Bool) -> RecognitionRouter {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "RecognitionRouterTests-\(UUID().uuidString)")!)
        settings.recognitionEngine = engine
        settings.language = languages[0]
        for language in languages.dropFirst() { settings.set(language, enabled: true) }
        return RecognitionRouter(
            parakeet: ParakeetEngine(), gigaam: GigaAMEngine(), settings: settings,
            gigaamInstalled: { installed }
        )
    }

    func testGigaAMOnlyForPureRussianWhenChosenAndInstalled() {
        XCTAssertTrue(router(engine: .gigaam, languages: [.ru], installed: true).usesGigaAM(for: .ru))
    }

    /// Пока модель качается, диктовки идут через Parakeet — выбор не оставляет без распознавания.
    func testFallsBackWhileNotInstalled() {
        XCTAssertFalse(router(engine: .gigaam, languages: [.ru], installed: false).usesGigaAM(for: .ru))
    }

    /// Смешанная речь — Parakeet: украинского GigaAM не знает, английские названия ломает.
    func testMixedLanguagesStayOnParakeet() {
        XCTAssertFalse(router(engine: .gigaam, languages: [.ru, .uk], installed: true).usesGigaAM(for: .ru))
        XCTAssertFalse(router(engine: .gigaam, languages: [.ru, .en], installed: true).usesGigaAM(for: .ru))
        XCTAssertFalse(router(engine: .gigaam, languages: [.uk], installed: true).usesGigaAM(for: .uk))
    }

    func testParakeetChoiceIsParakeet() {
        XCTAssertFalse(router(engine: .parakeet, languages: [.ru], installed: true).usesGigaAM(for: .ru))
    }

    /// Смена языков в меню доходит до маршрутизатора: снимок обновляется по подписке.
    func testFollowsLanguageChanges() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "RecognitionRouterTests-\(UUID().uuidString)")!)
        settings.recognitionEngine = .gigaam
        settings.language = .ru
        let router = RecognitionRouter(parakeet: ParakeetEngine(), gigaam: GigaAMEngine(), settings: settings,
                                       gigaamInstalled: { true })
        XCTAssertTrue(router.usesGigaAM(for: .ru))
        settings.set(.uk, enabled: true)
        XCTAssertFalse(router.usesGigaAM(for: .ru))
    }

    func testDefaultChoiceIsParakeet() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "RecognitionRouterTests-\(UUID().uuidString)")!)
        XCTAssertEqual(settings.recognitionEngine, .parakeet)
    }
}
