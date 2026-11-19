import XCTest
@testable import CribeCore

/// Кому шлём просьбу открыть дерево доступности.
final class FocusRequestTests: XCTestCase {

    /// Редакторам семейства VS Code — нет: на эту просьбу они включают режим для экранного
    /// диктора и выключают перенос строк. Ради одной диктовки ломать редактор нельзя.
    func testVSCodeFamilyIsNotAsked() {
        XCTAssertTrue(FocusedFieldDetector.refusesAccessibilityRequest("com.microsoft.VSCode"))
        XCTAssertTrue(FocusedFieldDetector.refusesAccessibilityRequest("com.todesktop.230313mzl4w4u92"))
    }

    /// Остальным — да: Claude и ChatGPT без просьбы не называют поле вовсе.
    func testOtherAppsAreAsked() {
        XCTAssertFalse(FocusedFieldDetector.refusesAccessibilityRequest("com.anthropic.claudefordesktop"))
        XCTAssertFalse(FocusedFieldDetector.refusesAccessibilityRequest("com.openai.codex"))
        XCTAssertFalse(FocusedFieldDetector.refusesAccessibilityRequest(nil))
    }
}
