import AppKit
import XCTest
@testable import Transcriber

/// Геометрия карточки, которую видит глаз: картинка под курсором и перелёт капсулы.
/// Обе вещи ломаются молча — на глаз «чуть не так», в логах ни строки, — поэтому числа.
@MainActor
final class CardVisualsTests: XCTestCase {

    /// Регрессия раунда: превью не знало высоты карточки (в нём нет шапки), выходило ниже
    /// неё, а кадр перетаскивания брался по КАРТОЧКЕ — AppKit растягивал картинку в кадр,
    /// и карточка под курсором ехала сплющенной по горизонтали.
    func testDragImageKeepsTheCardAspect() throws {
        let card = CardPanel(text: "короткая диктовка")
        let dragImage = try XCTUnwrap(card.dragImageForTesting, "картинка обязана строиться")
        let cardRect = CGRect(x: 0, y: 0, width: CardMetrics.width, height: card.cardHeight)
        let frame = CardPanel.dragFrame(cardRect: cardRect)

        let imageAspect = dragImage.size.width / dragImage.size.height
        let frameAspect = frame.width / frame.height
        XCTAssertEqual(
            imageAspect,
            frameAspect,
            accuracy: frameAspect * 0.01,
            "пропорция картинки и кадра расходится больше чем на процент — это и есть сплющивание"
        )
    }

    /// Многострочная карточка выше однострочной, и картинка обязана вырасти вместе с ней:
    /// фиксированная высота превью вернула бы ту же поломку на длинном тексте.
    func testDragImageFollowsCardHeight() throws {
        let short = CardPanel(text: "одна строка")
        let long = CardPanel(text: String(repeating: "длинная диктовка со многими словами ", count: 6))
        let shortImage = try XCTUnwrap(short.dragImageForTesting)
        let longImage = try XCTUnwrap(long.dragImageForTesting)

        XCTAssertGreaterThan(long.cardHeight, short.cardHeight, "четыре строки выше одной")
        XCTAssertGreaterThan(longImage.size.height, shortImage.size.height)
        XCTAssertEqual(shortImage.size.width, longImage.size.width, accuracy: 0.5, "ширина у карточек одна")
    }

    /// Кадр под курсором — это карточка плюс поле под тень и лёгкое увеличение. Проверяем
    /// именно то, что увеличение ОДНО на обе стороны: перекос множителей и есть сплющивание.
    func testDragFrameGrowsWithoutDistortion() {
        let cardRect = CGRect(x: 24, y: 24, width: CardMetrics.width, height: 120)
        let frame = CardPanel.dragFrame(cardRect: cardRect)
        let withShadow = cardRect.insetBy(dx: -CardMetrics.dragShadow, dy: -CardMetrics.dragShadow)

        XCTAssertEqual(frame.width / withShadow.width, CardMetrics.dragScale, accuracy: 0.001)
        XCTAssertEqual(frame.height / withShadow.height, CardMetrics.dragScale, accuracy: 0.001)
        XCTAssertEqual(frame.midX, withShadow.midX, accuracy: 0.001, "растём от центра, не от угла")
        XCTAssertEqual(frame.midY, withShadow.midY, accuracy: 0.001)
    }

    /// Окно перелёта обязано вмещать и старт, и финиш: фигура, вылезшая за край своего окна,
    /// обрезается — на середине пути от неё остался бы огрызок.
    func testFlightWindowCoversBothEnds() {
        let pill = CGRect(x: 661, y: 80, width: 190, height: 44)
        let card = CGRect(x: 16, y: 16, width: CardMetrics.width, height: 96)
        let window = CardFlight.windowFrame(from: pill, to: card)

        XCTAssertTrue(window.contains(pill), "старт внутри окна")
        XCTAssertTrue(window.contains(card), "финиш внутри окна")
    }

    /// Перевод в координаты окна перелёта переворачивает ось Y (SwiftUI считает сверху).
    /// Ошибка здесь не заметна на глаз сразу: фигура просто улетает не туда.
    func testFlightLocalRectFlipsVertically() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let rect = CGRect(x: 150, y: 120, width: 50, height: 40)
        let local = CardFlight.local(rect, in: window)

        XCTAssertEqual(local.minX, 50, "по горизонтали — простой сдвиг")
        XCTAssertEqual(local.size, rect.size, "габарит не меняется")
        // Верх прямоугольника (y = 160 снизу) лежит в 240 pt от верха окна (400 − 160).
        XCTAssertEqual(local.minY, 240)
    }

    /// Стык перелёта: карточка проявляется ВНУТРИ перелёта, а не после него, иначе между
    /// исчезнувшей фигурой и появившейся карточкой виден пустой кадр.
    func testFlightHandoffHappensInsideTheFlight() {
        XCTAssertGreaterThan(CardFlight.handoff, 0)
        XCTAssertLessThan(CardFlight.handoff, CardFlight.duration)
        XCTAssertEqual(CardFlight.duration, 0.42, accuracy: 0.001)
        XCTAssertEqual(CardFlight.response, 0.42, accuracy: 0.001)
        XCTAssertEqual(CardFlight.dampingFraction, 0.78, accuracy: 0.001)
    }

    /// После перелёта капсула молчит: «⤷ В карточку» посреди экрана — это второй раз про то,
    /// что и так показал перелёт. Вернуть её вправе только новая сессия.
    func testPillStaysSilentAfterHandingOffToTheCard() {
        XCTAssertFalse(
            LivePanel.wakesUp(handedOffToCard: true, next: .processing),
            "вспышка «В карточку» после перелёта читается как мигание"
        )
        XCTAssertFalse(LivePanel.wakesUp(handedOffToCard: true, next: .hidden))
        XCTAssertTrue(
            LivePanel.wakesUp(handedOffToCard: true, next: .starting),
            "новая диктовка обязана вернуть капсулу"
        )
        // Обычная доставка (вставка, отмена, ошибка) капсулу не глушит.
        for phase in [LivePanel.Phase.hidden, .starting, .processing] {
            XCTAssertTrue(LivePanel.wakesUp(handedOffToCard: false, next: phase))
        }
    }

    /// Перелёт и молчание капсулы — одна сделка: нет перелёта (Уменьшить движение) —
    /// значит, вспышка «⤷ В карточку» остаётся единственным ответом и глушить её нельзя.
    func testFlightAndSilenceGoTogether() {
        XCTAssertEqual(CardFlight.flies, !HUDAccessibility.shared.reduceMotion)
    }

    /// Оба окна HUD носят один рецепт: и капсула, и карточки обязаны появляться поверх
    /// чужого полноэкранного пространства. Расхождение здесь — это ровно та поломка,
    /// с которой начался раунд.
    func testHUDWindowRecipeIsSharedAndSticky() {
        XCTAssertTrue(HUDWindow.spaceBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(HUDWindow.spaceBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(HUDWindow.level, .statusBar)

        // Показ обязан ПЕРЕПОДАТЬ заявку: у долгоживущего окна она протухает.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = []
        HUDWindow.orderFront(window, extra: .stationary)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.stationary))
        window.orderOut(nil)
    }
}
