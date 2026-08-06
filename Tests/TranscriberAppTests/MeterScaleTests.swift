import XCTest
@testable import Transcriber

/// Шкала индикатора громкости. Тест существует из-за живой жалобы: «говорю за метр от
/// ноутбука, а волны почти не двигаются» — линейная шкала прижимала речь к нулю.
final class MeterScaleTests: XCTestCase {
    /// Тишина — ноль, отрицательных значений не бывает.
    func testSilenceIsFlat() {
        XCTAssertEqual(MeterScale.height(of: 0), 0)
        XCTAssertEqual(MeterScale.height(of: -1), 0)
    }

    /// Громче — выше, без исключений.
    func testLouderIsAlwaysHigher() {
        let levels: [Float] = [0.001, 0.005, 0.01, 0.02, 0.05, 0.1, 0.3, 1]
        let heights = levels.map { MeterScale.height(of: $0) }
        XCTAssertEqual(heights, heights.sorted(), "шкала обязана быть монотонной")
    }

    /// Речь с метра — это RMS порядка 0.01–0.02. Она должна быть отчётливо видна,
    /// а не шевелиться у самого низа: ровно этот случай и был сломан.
    func testSpeechFromAMeterIsClearlyVisible() {
        XCTAssertGreaterThan(MeterScale.height(of: 0.01), 0.3)
        XCTAssertGreaterThan(MeterScale.height(of: 0.02), 0.4)
    }

    /// Громкая речь упирается в полку, а не улетает за неё.
    func testLoudSpeechStaysWithinBounds() {
        XCTAssertLessThanOrEqual(MeterScale.height(of: 1), 1)
        XCTAssertGreaterThan(MeterScale.height(of: 0.3), 0.8)
    }
}
