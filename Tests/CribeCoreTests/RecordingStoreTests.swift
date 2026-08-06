import XCTest
@testable import CribeCore

/// Бэкап записей: ради него всё и затевалось — диктовка не должна пропадать бесследно.
/// Но голос на диске — самое личное, что есть у приложения, поэтому проверяем не только
/// «сохранилось», а и «не накопилось».
final class RecordingStoreTests: XCTestCase {
    private var folder: URL!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recordings-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Запись переживает распознавание и читается обратно — это и есть смысл бэкапа.
    func testSavedRecordingReadsBack() throws {
        let samples = Self.tone(seconds: 1)

        let saved = try XCTUnwrap(store.save(samples, keeping: 3))

        XCTAssertEqual(saved.seconds, 1, accuracy: 0.01)
        XCTAssertNotNil(store.url(named: saved.name))
        XCTAssertEqual(try store.samples(named: saved.name).count, samples.count)
    }

    /// Кольцо: четвёртая диктовка вытесняет первую. Иначе голос копился бы пачками.
    func testRingKeepsOnlyTheNewest() throws {
        var names: [String] = []
        for _ in 0..<4 {
            names.append(try XCTUnwrap(store.save(Self.tone(seconds: 0.2), keeping: 3)).name)
        }

        XCTAssertNil(store.url(named: names[0]), "самая старая запись обязана уйти")
        for name in names.dropFirst() {
            XCTAssertNotNil(store.url(named: name))
        }
    }

    /// Двум диктовкам подряд нужны разные файлы: имя по одной лишь метке времени
    /// схлопнуло бы их в один, и предыдущая запись пропала бы без всякого кольца.
    func testTwoRecordingsInARowDoNotCollide() throws {
        let first = try XCTUnwrap(store.save(Self.tone(seconds: 0.2), keeping: 3))
        let second = try XCTUnwrap(store.save(Self.tone(seconds: 0.2), keeping: 3))

        XCTAssertNotEqual(first.name, second.name)
        XCTAssertNotNil(store.url(named: first.name))
        XCTAssertNotNil(store.url(named: second.name))
    }

    /// Потолок длины: полчаса случайно оставленной записи на диск не лягут.
    func testLongRecordingIsTruncated() throws {
        let long = Self.tone(seconds: RecordingStore.maxSeconds + 30)

        let saved = try XCTUnwrap(store.save(long, keeping: 1))

        XCTAssertEqual(saved.seconds, RecordingStore.maxSeconds, accuracy: 0.01)
        XCTAssertEqual(try store.samples(named: saved.name).count,
                       AudioCaptureFormat.samples(seconds: RecordingStore.maxSeconds))
    }

    /// «Не хранить» означает «уже не хранится»: настройка не только запрещает новые записи,
    /// но и убирает те, что успели лечь.
    func testKeepingZeroStoresNothingAndClearsWhatWasThere() throws {
        let saved = try XCTUnwrap(store.save(Self.tone(seconds: 0.2), keeping: 3))

        XCTAssertNil(store.save(Self.tone(seconds: 0.2), keeping: 0))
        XCTAssertNil(store.url(named: saved.name))
        XCTAssertEqual(store.bytesOnDisk(), 0)
    }

    /// Кнопка «стереть записи» стирает всё до последнего файла.
    func testRemoveAll() throws {
        _ = store.save(Self.tone(seconds: 0.2), keeping: 3)
        _ = store.save(Self.tone(seconds: 0.2), keeping: 3)
        XCTAssertGreaterThan(store.bytesOnDisk(), 0)

        store.removeAll()

        XCTAssertEqual(store.bytesOnDisk(), 0)
    }

    /// Записи, которой нет, честно нет — вызывающий код обязан это увидеть, а не получить
    /// пустой буфер и распознать тишину.
    func testMissingRecordingThrows() {
        XCTAssertNil(store.url(named: "нет-такой.wav"))
        XCTAssertThrowsError(try store.samples(named: "нет-такой.wav"))
    }

    private static func tone(seconds: Double) -> [Float] {
        let count = AudioCaptureFormat.samples(seconds: seconds)
        return (0..<count).map { 0.5 * sin(Float($0) * 0.05) }
    }
}
