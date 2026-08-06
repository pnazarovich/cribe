import XCTest
@testable import TranscriberCore

/// Скачивание моделей движком. Сеть подменена точкой `downloadVariant`, папка моделей —
/// временная: ни одного байта настоящей модели тесты не тянут.
final class WhisperEngineDownloadTests: XCTestCase {
    private var base: URL!
    private var store: ModelStore!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperEngineDownloadTests-\(UUID().uuidString)")
        store = ModelStore(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Два запроса на один язык — одна загрузка: многогигабайтную модель второй раз не качаем.
    func testParallelDownloadsShareOneRun() async throws {
        let engine = WhisperEngine(store: store)
        let runs = Runs()
        engine.downloadVariant = { variant, onProgress in
            await runs.add(variant)
            try await Task.sleep(nanoseconds: 100_000_000)
            onProgress(1)
        }

        async let first: Void = engine.download(language: .ru, onProgress: { _ in })
        async let second: Void = engine.download(language: .ru, onProgress: { _ in })
        _ = try await (first, second)

        let variants = await runs.variants
        XCTAssertEqual(variants, [Language.ru.whisperModel])
    }

    /// Модель уже на диске — в сеть не идём вовсе.
    func testInstalledModelIsNotDownloadedAgain() async throws {
        try install(Language.ru.whisperModel)
        let engine = WhisperEngine(store: store)
        let runs = Runs()
        engine.downloadVariant = { variant, _ in await runs.add(variant) }

        try await engine.download(language: .ru, onProgress: { _ in })

        let variants = await runs.variants
        XCTAssertTrue(variants.isEmpty)
    }

    /// У каждого языка свой вариант: скачивание одного второй не заменяет.
    func testLanguagesDownloadTheirOwnVariant() async throws {
        let engine = WhisperEngine(store: store)
        let runs = Runs()
        engine.downloadVariant = { variant, _ in await runs.add(variant) }

        try await engine.download(language: .ru, onProgress: { _ in })
        try await engine.download(language: .uk, onProgress: { _ in })

        let variants = await runs.variants
        XCTAssertEqual(variants.sorted(), [Language.ru.whisperModel, Language.uk.whisperModel].sorted())
    }

    /// Английский работает на модели русского: у кого скачан русский, тот за английским
    /// в сеть не идёт вовсе. Это и есть причина не показывать английскому отдельные 1,5 ГБ.
    func testEnglishReusesTheRussianDownload() async throws {
        let engine = WhisperEngine(store: store)
        let runs = Runs()
        engine.downloadVariant = { [self] variant, _ in
            try install(variant)
            await runs.add(variant)
        }

        try await engine.download(language: .ru, onProgress: { _ in })
        try await engine.download(language: .en, onProgress: { _ in })

        let variants = await runs.variants
        XCTAssertEqual(variants, [WhisperModel.turbo], "английский обязан обойтись уже скачанным")
    }

    /// Отмена обрывает скачивание и освобождает место в списке идущих: следующая попытка
    /// начинается заново, а не залипает на отменённой.
    func testCancelledDownloadThrowsAndCanBeRetried() async throws {
        let engine = WhisperEngine(store: store)
        let runs = Runs()
        engine.downloadVariant = { variant, _ in
            await runs.add(variant)
            // Ждём отмены: настоящая загрузка тут качала бы гигабайты.
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        for expected in 1...2 {
            let task = Task { try await engine.download(language: .ru, onProgress: { _ in }) }
            try await waitForRuns(expected, in: runs)
            task.cancel()

            do {
                try await task.value
                XCTFail("Отменённое скачивание обязано бросить")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
    }

    /// Загрузка уже положила модель на диск, но сама не завершилась. Прогрев обязан идти
    /// мимо неё: ждать нечего, файлы на месте. Иначе диктовка висит на «Загружаю модель…»
    /// при нулевой нагрузке — ровно то, что поймали на первом запуске из DMG.
    func testStuckDownloadIsNotAwaitedOnceFilesAreOnDisk() async throws {
        let engine = WhisperEngine(store: store)
        let runs = Runs()
        engine.downloadVariant = { [self] variant, _ in
            // Файлы легли на диск…
            try install(variant)
            await runs.add(variant)
            // …а задача осталась висеть.
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }

        let stuck = Task { try await engine.download(language: .ru, onProgress: { _ in }) }
        defer { stuck.cancel() }
        try await waitForRuns(1, in: runs)

        let variant = Language.ru.whisperModel
        XCTAssertTrue(store.isInstalled(variant: variant), "модель обязана быть на диске")
        XCTAssertNil(
            engine.pendingDownload(forVariant: variant),
            "скачанную модель нельзя ставить в зависимость от незавершённой загрузки"
        )
    }

    // MARK: - Детали

    /// Счётчик заходов в «сеть»: движок зовёт `downloadVariant` из своей задачи, а проверяем
    /// мы из тестовой — значит, общее состояние обязано быть изолированным.
    private actor Runs {
        private(set) var variants: [String] = []

        func add(_ variant: String) {
            variants.append(variant)
        }
    }

    private func waitForRuns(_ count: Int, in runs: Runs, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await runs.variants.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Скачивание так и не началось", file: file, line: line)
    }

    /// Раскладка скачанной модели: три `.mlmodelc`, внутри каждой — файл весов.
    private func install(_ variant: String) throws {
        for part in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let model = store.folder(variant: variant).appendingPathComponent("\(part).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data(count: 16).write(to: model.appendingPathComponent("weights.bin"))
        }
    }
}
