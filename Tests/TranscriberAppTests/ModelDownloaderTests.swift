import XCTest
@testable import Transcriber
@testable import TranscriberCore

/// То, что видно в настройках до всякой сети: состояние моделей читается с диска,
/// удаление уносит ровно одну модель. Папка моделей — временная, скачиваний нет.
@MainActor
final class ModelDownloaderTests: XCTestCase {
    private var base: URL!
    private var store: ModelStore!

    private var turbo: ModelBundle { ModelBundle.bundle(for: .ru) }
    private var large: ModelBundle { ModelBundle.bundle(for: .uk) }

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)")
        store = ModelStore(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testEmptyDiskGivesMissingForEveryModel() {
        let downloader = ModelDownloader(store: store)

        for bundle in ModelBundle.all {
            XCTAssertEqual(downloader.state(of: bundle), .missing, bundle.displayName)
        }
        for language in Language.allCases {
            XCTAssertEqual(downloader.state(of: language), .missing, language.displayName)
        }
    }

    /// Уже скачанная модель показывается установленной сразу — предлагать скачать её заново
    /// (как делал онбординг) значит звать пользователя за гигабайтами, которые у него есть.
    func testInstalledModelIsSeenAtStart() throws {
        try install(turbo.variant, bytes: 4096)

        let downloader = ModelDownloader(store: store)

        guard case let .installed(bytes) = downloader.state(of: turbo) else {
            return XCTFail("turbo обязана читаться с диска как установленная")
        }
        XCTAssertGreaterThanOrEqual(bytes, 3 * 4096)
        XCTAssertEqual(downloader.state(of: large), .missing)
    }

    /// Модель могла доехать мимо настроек — её тянет первая диктовка. `refresh` это видит.
    func testRefreshPicksUpModelDownloadedElsewhere() throws {
        let downloader = ModelDownloader(store: store)
        XCTAssertEqual(downloader.state(of: large), .missing)

        try install(large.variant)
        downloader.refresh()

        XCTAssertEqual(downloader.state(of: large).isInstalled, true)
    }

    /// Удаление уносит папку одной модели и возвращает её в «не скачана». Вторую не трогает:
    /// ради этого всё и затевалось — русский без украинского и наоборот.
    func testRemoveDeletesOnlyItsOwnModel() throws {
        try install(turbo.variant)
        try install(large.variant)
        let downloader = ModelDownloader(store: store)

        try downloader.remove(turbo, engine: WhisperEngine(store: store))

        XCTAssertEqual(downloader.state(of: turbo), .missing)
        XCTAssertEqual(downloader.state(of: large).isInstalled, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(variant: turbo.variant).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(variant: large.variant).path))
    }

    // MARK: - Общая модель русского и английского

    /// Английский работает на модели русского: скачан русский — скачан и английский.
    /// Показывать английскому «не скачана · ≈1,5 ГБ» значило бы звать за уже лежащими файлами.
    func testEnglishSharesTheRussianModel() throws {
        try install(turbo.variant)
        let downloader = ModelDownloader(store: store)

        XCTAssertEqual(downloader.state(of: .en).isInstalled, true)
        XCTAssertEqual(downloader.state(of: .ru).isInstalled, true)
        XCTAssertEqual(downloader.state(of: .en), downloader.state(of: .ru))
    }

    /// Раскладка раздела «Модели распознавания»: строк ровно столько, сколько моделей,
    /// а не языков, и каждый язык попадает ровно в одну строку.
    func testSectionHasOneRowPerModelAndCoversEveryLanguage() {
        XCTAssertEqual(ModelBundle.all.count, 2, "turbo (RU + EN) и large-v3 (UK)")
        XCTAssertEqual(ModelBundle.all.flatMap(\.languages).count, Language.allCases.count)
        XCTAssertEqual(Set(ModelBundle.all.flatMap(\.languages)), Set(Language.allCases))
        XCTAssertEqual(ModelBundle.bundle(for: .ru).languages, [.ru, .en])
        XCTAssertEqual(ModelBundle.bundle(for: .uk).languages, [.uk])
    }

    /// Общая модель удаляется одной кнопкой и сразу у обоих языков: две строки удаляли бы
    /// одни и те же файлы, и «удалил английский» означало бы «сломал русский» молча.
    func testRemovingSharedModelTakesBothLanguagesAtOnce() throws {
        try install(turbo.variant)
        try install(large.variant)
        let downloader = ModelDownloader(store: store)

        try downloader.remove(ModelBundle.bundle(for: .en), engine: WhisperEngine(store: store))

        XCTAssertEqual(downloader.state(of: .en), .missing)
        XCTAssertEqual(downloader.state(of: .ru), .missing)
        // Украинская модель — своя папка, её общее удаление не касается.
        XCTAssertEqual(downloader.state(of: .uk).isInstalled, true)
    }

    /// Скачанная модель кнопкой «Скачать» никуда не идёт: движок видит файлы на диске.
    func testDownloadOfInstalledModelStaysOffline() async throws {
        try install(turbo.variant)
        let downloader = ModelDownloader(store: store)

        await downloader.download(turbo, engine: WhisperEngine(store: store))

        XCTAssertEqual(downloader.state(of: turbo).isInstalled, true)
    }

    /// Приблизительные размеры до скачивания: у turbo и large-v3 разница почти вдвое,
    /// и она и есть повод качать модели порознь.
    func testApproximateSizesDifferByModel() {
        XCTAssertLessThan(
            ModelDownloader.approximateBytes(for: turbo),
            ModelDownloader.approximateBytes(for: large)
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
