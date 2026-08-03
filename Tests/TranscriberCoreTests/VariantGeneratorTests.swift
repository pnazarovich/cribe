import XCTest
@testable import TranscriberCore

/// Транслитератор — офлайн-путь генерации вариантов, поэтому проверяется таблицей:
/// каждая строка — реальный термин из словаря и написание, которое обязано в списке быть.
final class TransliteratorTests: XCTestCase {

    /// Первый столбец — термин, дальше — написания, без которых вариант бесполезен.
    /// Все они взяты из живого словаря пользователя (или из спеки правил).
    private static let table: [(term: String, expected: [String])] = [
        // Спека: camelCase не даёт диграфу `th` съесть стык «Git|Hub».
        ("GitHub", ["гитхаб", "гітхаб"]),
        ("deploy", ["деплой"]),
        ("backend", ["бэкенд"]),
        ("Docker", ["докер"]),
        ("Telegram", ["телеграм"]),
        ("localhost", ["локалхост"]),
        ("Swift", ["свифт", "свіфт"]),
        ("Python", ["питон", "пітон"]),
        ("commit", ["коммит", "коміт"]),
        ("merge", ["мердж"]),
        ("Whisper", ["виспер", "віспер"]),
        ("pull request", ["пул реквест"]),
        // Правила из спеки поимённо.
        ("shell", ["шелл"]),          // sh
        ("chat", ["чат"]),            // ch
        ("phone", ["фон"]),           // ph + немая конечная e
        ("meeting", ["митинг"]),      // ee
        ("boot", ["бут"]),            // oo
        ("Java", ["джава"]),          // j
        ("Linux", ["линукс"]),        // x
        ("web", ["веб"]),             // w
        ("cell", ["селл"]),           // c перед e
        ("action", ["акшн"]),         // -tion
        ("policy", ["полиси", "полісі"]),  // конечная -y
    ]

    func testTableOfKnownTerms() {
        for row in Self.table {
            let variants = VariantGenerator.localVariants(for: row.term)
            for expected in row.expected {
                XCTAssertTrue(
                    variants.contains(expected),
                    "«\(row.term)» → ожидали «\(expected)», получили \(variants)"
                )
            }
        }
    }

    /// Оба языка обязаны быть в выдаче: словарь один на русский и украинский.
    func testUkrainianFormsUseIWithDot() {
        let variants = VariantGenerator.localVariants(for: "GitHub")
        XCTAssertTrue(variants.contains { $0.contains("і") }, variants.description)
        XCTAssertTrue(variants.contains { $0.contains("и") }, variants.description)
    }

    /// Удвоенная согласная — неоднозначность, а не ошибка: нужны оба написания.
    func testDoubledConsonantGivesBothSpellings() {
        let variants = VariantGenerator.localVariants(for: "commit")
        XCTAssertTrue(variants.contains("коммит"), variants.description)
        XCTAssertTrue(variants.contains("комит"), variants.description)
    }

    /// Основная форма идёт первой — обрезка списка сверху не должна терять главное.
    func testPrimaryFormComesFirst() {
        XCTAssertEqual(VariantGenerator.localVariants(for: "Docker").first, "докер")
        XCTAssertEqual(VariantGenerator.localVariants(for: "deploy").first, "деплой")
    }

    /// Кириллический термин транслитерировать не во что — и выдумывать нечего.
    func testCyrillicTermGivesNothing() {
        XCTAssertEqual(VariantGenerator.localVariants(for: "ТЗ"), [])
        XCTAssertEqual(VariantGenerator.localVariants(for: "заапрувить"), [])
        XCTAssertEqual(VariantGenerator.localVariants(for: "   "), [])
    }

    func testNeverExceedsTheCap() {
        for row in Self.table {
            XCTAssertLessThanOrEqual(
                VariantGenerator.localVariants(for: row.term).count,
                VariantGenerator.maxVariants,
                row.term
            )
        }
    }

    /// Термин сам себе вариантом быть не может: замена «X → X» бессмысленна.
    func testCanonicalIsNeverItsOwnVariant() {
        for row in Self.table {
            XCTAssertFalse(
                VariantGenerator.localVariants(for: row.term).contains(row.term.lowercased()),
                row.term
            )
        }
    }

    /// Детерминированность — единственная причина, по которой офлайн-путь вообще годится
    /// как запасной: один и тот же термин обязан давать один и тот же список.
    func testIsDeterministic() {
        XCTAssertEqual(
            VariantGenerator.localVariants(for: "GitHub"),
            VariantGenerator.localVariants(for: "GitHub")
        )
    }

    func testCamelCaseSplit() {
        XCTAssertEqual(Transliterator.camelParts("GitHub"), ["Git", "Hub"])
        XCTAssertEqual(Transliterator.camelParts("TypeScript"), ["Type", "Script"])
        XCTAssertEqual(Transliterator.camelParts("ChatGPT"), ["Chat", "GPT"])
        XCTAssertEqual(Transliterator.camelParts("API"), ["API"])
        XCTAssertEqual(Transliterator.camelParts("deploy"), ["deploy"])
        XCTAssertEqual(Transliterator.camelParts("OpenAI"), ["Open", "AI"])
    }
}

/// GPT-путь: сеть подменяется замыканием, проверяется контракт разбора и нормализации.
final class VariantGeneratorGPTTests: XCTestCase {

    private func variants(
        for term: String,
        timeout: TimeInterval = 20,
        answer: @escaping @Sendable (String) async throws -> String
    ) async throws -> [String] {
        try await VariantGenerator.variants(for: term, timeout: timeout) { _, input in
            try await answer(input)
        }
    }

    func testParsesJSONArray() async throws {
        let result = try await variants(for: "GitHub") { _ in
            #"["гитхаб", "гіт хаб", "гит хаб"]"#
        }
        XCTAssertEqual(result, ["гитхаб", "гіт хаб", "гит хаб"])
    }

    func testParsesFencedJSON() async throws {
        let result = try await variants(for: "deploy") { _ in
            """
            ```json
            ["деплой", "деплоить"]
            ```
            """
        }
        XCTAssertEqual(result, ["деплой", "деплоить"])
    }

    /// Модель нередко отвечает списком, а не массивом, — это тоже валидный ответ.
    func testParsesNumberedLines() async throws {
        let result = try await variants(for: "Docker") { _ in
            """
            1. докер
            2) докерить
            - доккер
            """
        }
        XCTAssertEqual(result, ["докер", "докерить", "доккер"])
    }

    /// Нормализация одна на оба пути: регистр, дубли, сам термин и мусор отсекаются.
    func testNormalizesAnswer() async throws {
        let result = try await variants(for: "GitHub") { _ in
            #"["ГитХаб", "гитхаб", "  гит хаб  ", "GitHub", "", "—"]"#
        }
        XCTAssertEqual(result, ["гитхаб", "гит хаб"])
    }

    func testCapsAtMaxVariants() async throws {
        let long = (1...20).map { "вариант\($0)" }
        let result = try await variants(for: "term") { _ in long.joined(separator: "\n") }
        XCTAssertEqual(result.count, VariantGenerator.maxVariants)
    }

    /// Термин уезжает входом, а не инструкцией: так он остаётся данными.
    func testSendsTermAsInput() async throws {
        let box = Box()
        _ = try await VariantGenerator.variants(for: "Kubernetes") { instructions, input in
            box.instructions = instructions
            box.input = input
            return "[]"
        }
        XCTAssertEqual(box.input, "Kubernetes")
        XCTAssertTrue(box.instructions?.contains("голосового ввода") == true)
        XCTAssertFalse(box.instructions?.contains("Kubernetes") == true)
    }

    func testPropagatesFailure() async {
        do {
            _ = try await variants(for: "term") { _ in throw GPTClientError.empty }
            XCTFail("ошибка модели обязана дойти до вызывающего кода")
        } catch {
            XCTAssertTrue(error is GPTClientError, "\(error)")
        }
    }

    func testTimesOut() async {
        do {
            _ = try await variants(for: "term", timeout: 0.05) { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "[]"
            }
            XCTFail("медленный ответ обязан обрываться таймаутом")
        } catch {
            XCTAssertTrue(error is PostProcessorError, "\(error)")
        }
    }

    func testEmptyTermNeverGoesToTheModel() async throws {
        let result = try await variants(for: "   ") { _ in
            XCTFail("пустой термин к модели не ходит")
            return "[]"
        }
        XCTAssertEqual(result, [])
    }
}

/// Захват из `@Sendable`-замыкания: тесту нужен доступ к тому, что уехало в модель.
private final class Box: @unchecked Sendable {
    var instructions: String?
    var input: String?
}
