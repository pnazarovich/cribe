import XCTest
@testable import TranscriberCore

final class UserDictionaryTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UserDictionaryTests-\(UUID().uuidString)")
        url = dir.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDefaultURLPointsAtApplicationSupport() {
        let path = UserDictionary.defaultURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/Transcriber/dictionary.json"), path)
    }

    func testCreatesFileWithDefaultEntriesWhenMissing() throws {
        let dict = UserDictionary(url: url)
        XCTAssertEqual(dict.entries, defaultEntries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let onDisk = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk, defaultEntries)
    }

    func testLoadsExistingFile() throws {
        let stored = [DictionaryEntry(canonical: "Kubernetes", variants: ["кубернетес"])]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url)

        XCTAssertEqual(UserDictionary(url: url).entries, stored)
    }

    func testReplacePersistsAndNotifies() throws {
        let dict = UserDictionary(url: url)
        let notified = expectation(description: "onChange")
        dict.onChange = { notified.fulfill() }

        let updated = [DictionaryEntry(canonical: "Redis", variants: ["редис"])]
        dict.replace(entries: updated)

        XCTAssertEqual(dict.entries, updated)
        wait(for: [notified], timeout: 2)
        XCTAssertNil(dict.lastSaveError)
        XCTAssertEqual(UserDictionary(url: url).entries, updated)
    }

    func testFailedSaveIsReportedInLastSaveError() {
        // /dev/null — не каталог, создать в нём файл нельзя.
        let dict = UserDictionary(url: URL(fileURLWithPath: "/dev/null/nope/dictionary.json"))
        XCTAssertNotNil(dict.lastSaveError)
        XCTAssertEqual(dict.entries, defaultEntries)
    }

    func testExternalEditTriggersOnChange() throws {
        let dict = UserDictionary(url: url)
        let notified = expectation(description: "onChange")
        dict.onChange = { notified.fulfill() }

        let external = [DictionaryEntry(canonical: "Postgres", variants: ["постгрес"])]
        try JSONEncoder().encode(external).write(to: url, options: .atomic)

        wait(for: [notified], timeout: 5)
        XCTAssertEqual(dict.entries, external)
    }

    func testInPlaceEditTriggersOnChange() throws {
        let dict = UserDictionary(url: url)
        let notified = expectation(description: "onChange")
        dict.onChange = { notified.fulfill() }

        // Без .atomic — правка «на месте», каталог при этом не меняется.
        let external = [DictionaryEntry(canonical: "Kafka", variants: ["кафка"])]
        try JSONEncoder().encode(external).write(to: url)

        wait(for: [notified], timeout: 5)
        XCTAssertEqual(dict.entries, external)
    }

    func testCorruptedFileFallsBackToDefaultsWithoutOverwriting() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        XCTAssertEqual(UserDictionary(url: url).entries, defaultEntries)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }
}
