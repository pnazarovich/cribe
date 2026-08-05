import XCTest
@testable import Transcriber
@testable import TranscriberCore

/// То, что видно в настройках до всякой сети: состояние моделей читается с диска,
/// удаление уносит ровно один язык. Папка моделей — временная, скачиваний нет.
@MainActor
final class ModelDownloaderTests: XCTestCase {
    private var base: URL!
    private var store: ModelStore!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)")
        store = ModelStore(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testEmptyDiskGivesMissingForBothLanguages() {
        let downloader = ModelDownloader(store: store)

        XCTAssertEqual(downloader.states[.ru], .missing)
        XCTAssertEqual(downloader.states[.uk], .missing)
    }

    /// Уже скачанный язык показывается установленным сразу — предлагать скачать его заново
    /// (как делал онбординг) значит звать пользователя за гигабайтами, которые у него есть.
    func testInstalledLanguageIsSeenAtStart() throws {
        try install(Language.ru.whisperModel, bytes: 4096)

        let downloader = ModelDownloader(store: store)

        guard case let .installed(bytes) = downloader.states[.ru] else {
            return XCTFail("Русский обязан читаться с диска как установленный")
        }
        XCTAssertGreaterThanOrEqual(bytes, 3 * 4096)
        XCTAssertEqual(downloader.states[.uk], .missing)
    }

    /// Модель могла доехать мимо настроек — её тянет первая диктовка. `refresh` это видит.
    func testRefreshPicksUpModelDownloadedElsewhere() throws {
        let downloader = ModelDownloader(store: store)
        XCTAssertEqual(downloader.states[.uk], .missing)

        try install(Language.uk.whisperModel)
        downloader.refresh()

        XCTAssertEqual(downloader.states[.uk]?.isInstalled, true)
    }

    /// Удаление уносит папку одного языка и возвращает его в «не скачана». Второй не трогает:
    /// ради этого всё и затевалось — русский без украинского и наоборот.
    func testRemoveDeletesOnlyItsOwnLanguage() throws {
        try install(Language.ru.whisperModel)
        try install(Language.uk.whisperModel)
        let downloader = ModelDownloader(store: store)

        try downloader.remove(.ru, engine: WhisperEngine(store: store))

        XCTAssertEqual(downloader.states[.ru], .missing)
        XCTAssertEqual(downloader.states[.uk]?.isInstalled, true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.folder(variant: Language.ru.whisperModel).path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.folder(variant: Language.uk.whisperModel).path)
        )
    }

    /// Скачанный язык кнопкой «Скачать» никуда не идёт: движок видит файлы на диске.
    func testDownloadOfInstalledLanguageStaysOffline() async throws {
        try install(Language.ru.whisperModel)
        let downloader = ModelDownloader(store: store)

        await downloader.download(.ru, engine: WhisperEngine(store: store))

        XCTAssertEqual(downloader.states[.ru]?.isInstalled, true)
    }

    /// Приблизительные размеры до скачивания: у русского turbo, у украинского large-v3 —
    /// разница почти вдвое, и она и есть повод качать языки порознь.
    func testApproximateSizesDifferByLanguage() {
        XCTAssertLessThan(
            ModelDownloader.approximateBytes(for: .ru),
            ModelDownloader.approximateBytes(for: .uk)
        )
    }

    /// Раскладка скачанной модели: три `.mlmodelc`, внутри каждой — файл весов.
    private func install(_ variant: String, bytes: Int = 1024) throws {
        for part in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let model = store.folder(variant: variant).appendingPathComponent("\(part).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: model.appendingPathComponent("weights.bin"))
        }
    }
}
