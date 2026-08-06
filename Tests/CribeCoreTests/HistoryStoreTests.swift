import XCTest
@testable import CribeCore

final class HistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "history-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Диктовка помнит свою запись — без этого «распознать заново» вести некуда.
    func testItemRemembersItsRecording() {
        let store = HistoryStore(defaults: defaults)

        store.add("привет", language: .ru, audio: "1.wav", seconds: 12)

        XCTAssertEqual(store.items.first?.audio, "1.wav")
        XCTAssertEqual(store.items.first?.seconds, 12)
    }

    /// Диктовка, из которой распознавание не вытащило ни слова, всё равно попадает в историю:
    /// текста нет, зато есть звук — и это единственная дверь к нему.
    func testFailedDictationStillGetsARow() {
        let store = HistoryStore(defaults: defaults)

        store.add("", language: .ru, audio: "1.wav", seconds: 40)
        XCTAssertTrue(store.items.isEmpty, "пустой текст без звука истории не нужен")

        store.addFailed(language: .ru, audio: "1.wav", seconds: 40)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "")
        XCTAssertEqual(store.items.first?.audio, "1.wav")
    }

    /// Повторное распознавание заменяет текст на месте, не заводя вторую строку и не теряя
    /// привязку к записи: разобрать её можно и в третий раз.
    func testRetranscribeReplacesTextInPlace() throws {
        let store = HistoryStore(defaults: defaults)
        store.addFailed(language: .ru, audio: "1.wav", seconds: 40)
        let id = try XCTUnwrap(store.items.first?.id)

        store.replace(id: id, text: "  вот что там было  ")

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "вот что там было")
        XCTAssertEqual(store.items.first?.audio, "1.wav")
    }

    /// История длиннее кольца записей: строки, чей звук вытеснен, не должны предлагать
    /// кнопку в никуда, а пустая строка без звука уже вообще ничем не является.
    func testForgetsRecordingsThatAreGone() {
        let store = HistoryStore(defaults: defaults)
        store.addFailed(language: .ru, audio: "старая.wav", seconds: 40)
        store.add("текст", language: .ru, audio: "старая.wav", seconds: 40)
        store.add("свежая", language: .ru, audio: "свежая.wav", seconds: 10)

        store.forgetAudio { $0 == "свежая.wav" }

        XCTAssertEqual(store.items.map(\.text), ["свежая", "текст"])
        XCTAssertEqual(store.items.first?.audio, "свежая.wav")
        XCTAssertNil(store.items.last?.audio)
    }

    /// Старая история (без полей записи) читается как есть — обновление не стирает её.
    func testOldHistoryWithoutAudioFieldsDecodes() throws {
        let legacy = """
            [{"id":"\(UUID().uuidString)","date":0,"text":"старая диктовка","language":"ru"}]
            """
        defaults.set(Data(legacy.utf8), forKey: "history")

        let store = HistoryStore(defaults: defaults)

        XCTAssertEqual(store.items.first?.text, "старая диктовка")
        XCTAssertNil(store.items.first?.audio)
    }

    /// Кольцо истории прежнее: 20 записей, новые сверху.
    func testLimitIsKept() {
        let store = HistoryStore(defaults: defaults)

        for index in 0..<(HistoryStore.limit + 5) {
            store.add("диктовка \(index)", language: .ru)
        }

        XCTAssertEqual(store.items.count, HistoryStore.limit)
        XCTAssertEqual(store.items.first?.text, "диктовка \(HistoryStore.limit + 4)")
    }
}
