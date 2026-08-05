import XCTest
@testable import TranscriberCore

/// Модели на диске: что считается скачанным, сколько это занимает и как удаляется.
/// Всё на временной папке — настоящие модели тесты не трогают и уж точно не качают.
final class ModelStoreTests: XCTestCase {
    private var base: URL!
    private var store: ModelStore!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)")
        store = ModelStore(base: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testSharedStoreLivesInApplicationSupport() {
        let path = ModelStore.shared.base.path
        XCTAssertTrue(path.hasSuffix("/Application Support/Transcriber/models"), path)
    }

    /// Раскладка HubApi: её же ждёт WhisperKit, когда ищет модель на диске.
    func testFolderFollowsHubLayout() {
        XCTAssertEqual(
            store.folder(variant: WhisperModel.turbo).path,
            base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(WhisperModel.turbo)").path
        )
    }

    func testMissingModelIsNotInstalled() {
        XCTAssertFalse(store.isInstalled(variant: WhisperModel.turbo))
        XCTAssertNil(store.installedFolder(variant: WhisperModel.turbo))
        XCTAssertEqual(store.sizeOnDisk(variant: WhisperModel.turbo), 0)
    }

    /// Недокачанная папка за модель не идёт: с двумя моделями из трёх WhisperKit не поднимется,
    /// и показывать такую «установленной» — обещать работающую диктовку, которой не будет.
    func testPartialModelIsNotInstalled() throws {
        try install(WhisperModel.turbo, parts: ["MelSpectrogram", "AudioEncoder"])

        XCTAssertFalse(store.isInstalled(variant: WhisperModel.turbo))
        XCTAssertNil(store.installedFolder(variant: WhisperModel.turbo))
    }

    func testCompleteModelIsInstalled() throws {
        try install(WhisperModel.turbo)

        XCTAssertTrue(store.isInstalled(variant: WhisperModel.turbo))
        XCTAssertEqual(store.installedFolder(variant: WhisperModel.turbo), store.folder(variant: WhisperModel.turbo))
    }

    /// Размер считается по файлам внутри: `.mlmodelc` — сама папка, и снаружи её вес не виден.
    func testSizeCountsFilesInsideModelFolders() throws {
        try install(WhisperModel.turbo, bytes: 4096)

        // Файловая система округляет вверх до блока — точного равенства тут не бывает.
        XCTAssertGreaterThanOrEqual(store.sizeOnDisk(variant: WhisperModel.turbo), 3 * 4096)
        XCTAssertEqual(store.sizeOnDisk(variant: WhisperModel.large), 0)
    }

    func testRemoveDeletesModelFromDisk() throws {
        try install(WhisperModel.large)

        try store.remove(variant: WhisperModel.large)

        XCTAssertFalse(store.isInstalled(variant: WhisperModel.large))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(variant: WhisperModel.large).path))
    }

    /// Языки удаляются порознь: русский остаётся на месте, когда сносят украинский.
    func testRemoveTouchesOnlyItsOwnVariant() throws {
        try install(WhisperModel.turbo)
        try install(WhisperModel.large)

        try store.remove(variant: WhisperModel.large)

        XCTAssertTrue(store.isInstalled(variant: WhisperModel.turbo))
        XCTAssertFalse(store.isInstalled(variant: WhisperModel.large))
    }

    /// Удаление идемпотентно: удалять нечего — не ошибка.
    func testRemoveOfMissingModelDoesNothing() {
        XCTAssertNoThrow(try store.remove(variant: WhisperModel.large))
    }

    /// Раскладка скачанной модели: три `.mlmodelc`, внутри каждой — файл весов.
    private func install(
        _ variant: String,
        parts: [String] = ["MelSpectrogram", "AudioEncoder", "TextDecoder"],
        bytes: Int = 1024
    ) throws {
        for part in parts {
            let model = store.folder(variant: variant).appendingPathComponent("\(part).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: model.appendingPathComponent("weights.bin"))
        }
    }
}
