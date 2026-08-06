import XCTest
@testable import Cribe
import CribeCore

/// Правка диктовки в окне истории. Проверяется то, ради чего окно и достраивали: текст,
/// поправленный руками, доезжает до истории и переживает закрытие окна — а значит, и
/// перезапуск приложения, потому что история лежит в UserDefaults.
@MainActor
final class HistoryEditTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "history-edit-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeHistory(_ texts: String...) -> HistoryStore {
        let store = HistoryStore(defaults: defaults)
        for text in texts { store.add(text, language: .ru) }
        return store
    }

    /// Главное утверждение задачи: правка уезжает в историю и остаётся там после того,
    /// как окно закрыли. Второй `HistoryStore` на тех же настройках — это и есть
    /// следующий запуск приложения: он читает историю заново, с диска.
    func testEditReachesHistoryAndSurvivesTheWindowClosing() throws {
        let history = makeHistory("превет из диктовки")
        let item = try XCTUnwrap(history.items.first)
        let model = HistoryModel()

        model.expand(item)
        XCTAssertEqual(model.draft, "превет из диктовки", "раскрытая строка правится своим текстом")

        model.draft = "привет из диктовки"
        model.edited(in: history)
        // Окно закрыли, не дожидаясь таймера, — ровно то, что делает `onDisappear`.
        model.flush()

        XCTAssertEqual(history.items.first?.text, "привет из диктовки")
        XCTAssertEqual(
            HistoryStore(defaults: defaults).items.first?.text,
            "привет из диктовки",
            "правка легла на диск, а не осталась в памяти окна"
        )
    }

    /// Свернуть строку — тоже конец правки: ждать таймера незачем.
    func testCollapsingWritesTheEdit() throws {
        let history = makeHistory("первая версия")
        let item = try XCTUnwrap(history.items.first)
        let model = HistoryModel()

        model.expand(item)
        model.draft = "вторая версия"
        model.edited(in: history)
        model.collapse()

        XCTAssertNil(model.expanded)
        XCTAssertEqual(history.items.first?.text, "вторая версия")
    }

    /// Переход к другой диктовке не теряет недописанное: раскрытая строка одна, и её
    /// черновик обязан лечь в историю прежде, чем на его место придёт чужой текст.
    func testOpeningAnotherRowKeepsThePreviousEdit() throws {
        let history = makeHistory("старая диктовка", "свежая диктовка")
        let fresh = try XCTUnwrap(history.items.first)
        let old = try XCTUnwrap(history.items.last)
        let model = HistoryModel()

        model.expand(fresh)
        model.draft = "свежая диктовка, поправлено"
        model.edited(in: history)

        model.expand(old)

        XCTAssertEqual(model.draft, "старая диктовка")
        XCTAssertEqual(history.items.first?.text, "свежая диктовка, поправлено")
    }

    /// Пустой строкой диктовку не стирают. Пустой текст в истории означает совсем другое —
    /// «распознать не удалось», и строка живёт ради записи; случайное выделение и Delete
    /// не должны превращать одно в другое.
    func testEmptyDraftDoesNotEraseTheDictation() throws {
        let history = makeHistory("диктовка на месте")
        let item = try XCTUnwrap(history.items.first)
        let model = HistoryModel()

        model.expand(item)
        model.draft = "   \n "
        model.edited(in: history)
        model.flush()

        XCTAssertEqual(history.items.first?.text, "диктовка на месте")
    }

    /// Карточка приходит со своим текстом, а не с id — его у неё нет. Строку по тексту
    /// находим ту самую и самую свежую.
    func testCardTextFindsItsRow() throws {
        let history = makeHistory("одна и та же фраза", "другая диктовка", "одна и та же фраза")
        let newest = try XCTUnwrap(history.items.first)

        XCTAssertEqual(
            HistoryModel.row(matching: "  одна и та же фраза\n", in: history.items)?.id,
            newest.id,
            "повторов бывает много — берём последний"
        )
        XCTAssertNil(HistoryModel.row(matching: "такого не диктовали", in: history.items))
        XCTAssertNil(HistoryModel.row(matching: "  ", in: history.items))
    }

    /// Карточка уводит в историю ОРИГИНАЛОМ, даже когда на ней показан перевод: в истории
    /// лежит оригинал, и по переводу строка не нашлась бы вовсе.
    func testCardExpandsWithTheOriginalEvenWhenShowingTranslation() async throws {
        let asked = Asked()
        let card = CardPanel(
            text: "привет из диктовки",
            translator: CardTranslator(
                isAvailable: { true },
                translate: { "translation of \($0)" }
            ),
            onExpand: { text in asked.texts.append(text) }
        )

        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(card.showsTranslationForTesting, "на карточке перевод")

        card.expandForTesting()

        XCTAssertEqual(asked.texts, ["привет из диктовки"])
    }

    /// Копилка для того, о чём карточку попросили: замыкание уезжает наружу, и захватить
    /// туда обычную переменную нечем.
    private final class Asked: @unchecked Sendable {
        var texts: [String] = []
    }
}
