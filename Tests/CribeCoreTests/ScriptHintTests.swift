import XCTest
@testable import CribeCore

/// Подсказка письменности для FluidAudio.
///
/// С первого дня Cribe передавал декодеру язык сессии, и для русского с украинским это
/// включало фильтр, отбрасывающий любой токен с латинскими буквами. «Гитхаб» вместо GitHub
/// годами считалось свойством модели, а было этой настройкой. Замер на записях владельца:
/// без подсказки 7 английских названий из 15 приходят латиницей прямо из распознавания,
/// ложной латиницы в русских словах — ноль.
final class ScriptHintTests: XCTestCase {

    /// Кириллическим языкам письменность не навязываем.
    func testCyrillicSessionsGetNoScriptFilter() {
        XCTAssertNil(ParakeetEngine.scriptHint(for: .ru))
        XCTAssertNil(ParakeetEngine.scriptHint(for: .uk))
    }

    /// Английской — навязываем: там фильтр отсекает кириллицу, ради чего и написан.
    func testEnglishSessionKeepsItsFilter() {
        XCTAssertEqual(ParakeetEngine.scriptHint(for: .en), "en")
    }
}
