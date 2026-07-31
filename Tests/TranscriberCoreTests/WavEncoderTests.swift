import XCTest
@testable import TranscriberCore

final class WavEncoderTests: XCTestCase {

    func testHeaderDescribes16BitMono16kHz() {
        let data = WavEncoder.encode([0, 0, 0, 0])

        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        XCTAssertEqual(le32(data, 4), UInt32(36 + 8))   // размер RIFF
        XCTAssertEqual(le16(data, 20), 1)               // PCM
        XCTAssertEqual(le16(data, 22), 1)               // моно
        XCTAssertEqual(le32(data, 24), 16_000)          // частота
        XCTAssertEqual(le32(data, 28), 32_000)          // байт в секунду
        XCTAssertEqual(le16(data, 32), 2)               // выравнивание блока
        XCTAssertEqual(le16(data, 34), 16)              // бит на сэмпл
        XCTAssertEqual(le32(data, 40), 8)               // размер данных
    }

    func testSamplesAreScaledAndClamped() {
        let data = WavEncoder.encode([0, 1, -1, 2, -2])

        XCTAssertEqual(Int16(bitPattern: le16(data, 44)), 0)
        XCTAssertEqual(Int16(bitPattern: le16(data, 46)), 32_767)
        XCTAssertEqual(Int16(bitPattern: le16(data, 48)), -32_767)
        XCTAssertEqual(Int16(bitPattern: le16(data, 50)), 32_767)
        XCTAssertEqual(Int16(bitPattern: le16(data, 52)), -32_767)
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }
}
