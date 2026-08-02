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
    /// исчезнувшей фигурой и появившейся карточкой виден пустой кадр. Стык обязан лежать
    /// внутри последнего участка — посадки, — иначе карточка проявится ещё в воздухе.
    func testFlightHandoffHappensInsideTheLanding() {
        XCTAssertGreaterThan(CardFlight.handoff, 0)
        XCTAssertLessThan(CardFlight.handoff, CardFlight.land)
        XCTAssertEqual(
            CardFlight.duration,
            CardFlight.gather + CardFlight.detach + CardFlight.fall + CardFlight.land,
            accuracy: 0.0001
        )
        XCTAssertEqual(CardFlight.duration, 0.75, accuracy: 0.001, "вся хореография — три четверти секунды")
    }

    /// Дуга падения: тело идёт не по прямой (иначе это «переезд», а не падение) и
    /// приходит ровно в карточку.
    func testFallArcBendsAndLandsExactly() {
        let start = CGPoint(x: 700, y: 100)
        let end = CGPoint(x: 100, y: 500)
        XCTAssertEqual(CardFlight.point(on: 0, from: start, to: end), start)
        XCTAssertEqual(CardFlight.point(on: 1, from: start, to: end), end)

        let middle = CardFlight.point(on: 0.5, from: start, to: end)
        let straight = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        XCTAssertLessThan(middle.x, straight.x, "середина пути уведена влево — это и есть дуга")
    }

    /// Разгон: за первую половину времени тело проходит заметно меньше половины пути.
    /// Ровно этого и просили — медленный старт, быстрый конец.
    func testFallAccelerates() {
        let start = CGPoint(x: 700, y: 100)
        let end = CGPoint(x: 100, y: 500)
        let full = hypot(end.x - start.x, end.y - start.y)
        let atHalf = CardFlight.point(on: 0.35, from: start, to: end)
        let travelled = hypot(atHalf.x - start.x, atHalf.y - start.y)
        XCTAssertLessThan(travelled / full, 0.5, "к трети времени пройдено меньше половины пути")
    }

    /// «Сплющить-растянуть»: чем быстрее, тем длиннее по ходу и ровно настолько же тоньше
    /// поперёк. Это и есть вся «жидкость» — без неё капсула просто переезжает, а с перекосом
    /// множителей фигура на глазах РАСТЁТ, чего в природе капли не бывает.
    func testStretchElongatesAndThinsWithSpeed() {
        let rest = CardFlight.stretch(at: 0)
        XCTAssertEqual(rest.width, 1, accuracy: 0.0001, "на старте тело не тронуто")
        XCTAssertEqual(rest.height, 1, accuracy: 0.0001)

        let peak = CardFlight.stretch(at: 1)
        XCTAssertEqual(peak.width, 1.35, accuracy: 0.0001, "на полной скорости длиннее в 1.35")
        XCTAssertEqual(peak.height, 0.80, accuracy: 0.0001, "и настолько же тоньше")
        XCTAssertEqual(peak.width * peak.height, 1, accuracy: 0.1, "площадь держится: фигура не растёт")

        // По дороге — монотонно, без рывков в обе стороны.
        var previous = rest
        for step in 1...10 {
            let next = CardFlight.stretch(at: CGFloat(step) / 10)
            XCTAssertGreaterThan(next.width, previous.width)
            XCTAssertLessThan(next.height, previous.height)
            previous = next
        }

        // За краями участка ничего не разъезжается: доля пути подрезана с обеих сторон.
        XCTAssertEqual(CardFlight.stretch(at: -1).width, 1, accuracy: 0.0001)
        XCTAssertEqual(CardFlight.stretch(at: 2).width, peak.width, accuracy: 0.0001)
    }

    /// Радиус — единственное, чем силуэт вообще меняется за перелёт: от круглых торцов
    /// капсулы до скругления карточки. Концы обязаны совпадать точно, иначе на стыке
    /// видно, как углы «доезжают» уже после того, как карточка проявилась.
    func testCornerMorphsFromCapsuleToCard() {
        let capsule = PanelPill.height / 2
        XCTAssertEqual(
            CardFlight.corner(at: 0, from: capsule, to: CardMetrics.corner),
            capsule,
            accuracy: 0.0001,
            "на старте торцы круглые — это капсула"
        )
        XCTAssertEqual(
            CardFlight.corner(at: 1, from: capsule, to: CardMetrics.corner),
            CardMetrics.corner,
            accuracy: 0.0001,
            "к концу падения радиус уже карточкин"
        )

        let middle = CardFlight.corner(at: 0.5, from: capsule, to: CardMetrics.corner)
        XCTAssertLessThan(middle, capsule, "по дороге радиус ползёт вниз")
        XCTAssertGreaterThan(middle, CardMetrics.corner)
    }

    /// Наклон идёт за касательной к дуге, но подрезан: капсула, завалившаяся на полтора
    /// десятка градусов, читается уже чужим предметом, а не той же самой пилюлей.
    func testTiltFollowsTheTangentButStaysSubtle() {
        // Настоящая геометрия: капсула у нижнего края экрана, карточка в левом нижнем углу.
        let pill = CGRect(x: 661, y: 104, width: PanelPill.width, height: PanelPill.height)
        let card = CGRect(x: 16, y: 16, width: CardMetrics.width, height: 96)
        let window = CardFlight.windowFrame(from: pill, to: card)
        let start = CardFlight.local(pill, in: window)
        let finish = CardFlight.local(card, in: window)
        let from = CGPoint(x: start.midX, y: start.midY)
        let to = CGPoint(x: finish.midX, y: finish.midY)

        for step in 0...20 {
            let tilt = CardFlight.tilt(on: CGFloat(step) / 20, from: from, to: to)
            XCTAssertLessThanOrEqual(abs(tilt), CardFlight.maxTilt, "наклон подрезан на всей дуге")
        }

        let atStart = CardFlight.tilt(on: 0, from: from, to: to)
        let atEnd = CardFlight.tilt(on: 1, from: from, to: to)
        XCTAssertGreaterThan(abs(atStart), 0.001, "уже на старте тело чуть завалено по касательной")
        XCTAssertLessThan(atStart, 0, "дуга уходит влево-вниз — наклон в одну сторону")
        XCTAssertLessThan(atEnd, 0, "и к концу он не переворачивается")
        XCTAssertGreaterThan(abs(atEnd), abs(atStart), "к концу дуга круче — и наклон больше")
    }

    /// Задняя кромка отстаёт и тянет смаз, но НЕ отрывается: оторвавшийся смаз читается
    /// вторым предметом, а не жидкостью, не поспевающей за собой.
    func testTrailLagsBehindButNeverTearsOff() {
        let lead = CGPoint(x: 100, y: 100)
        XCTAssertEqual(CardFlight.trailOffset(lead: lead, trail: lead), .zero, "стоящее тело смаза не даёт")

        // Близкая кромка отстаёт как есть.
        let near = CardFlight.trailOffset(lead: lead, trail: CGPoint(x: 110, y: 100))
        XCTAssertEqual(near.width, 10, accuracy: 0.0001)

        // Далёкая — подтягивается к потолку, но направление сохраняет.
        let far = CardFlight.trailOffset(lead: lead, trail: CGPoint(x: 500, y: 100))
        XCTAssertEqual(hypot(far.width, far.height), CardFlight.trailReach, accuracy: 0.0001)
        XCTAssertGreaterThan(far.width, 0, "смаз всегда позади тела, по ходу назад")
    }

    /// Растекание: на посадке высота садится первой, а ширина наливается в рамку последней —
    /// пружиной, с одной мягкой волной. Радиус к этому моменту уже совпал (он доехал ещё
    /// в полёте, см. `testCornerMorphsFromCapsuleToCard`), и на земле остаётся только ширина.
    func testWidthPoursIntoTheFrameLast() {
        XCTAssertLessThan(CardFlight.landHeight, CardFlight.land, "высота садится внутри посадки")
        XCTAssertLessThan(
            CardFlight.landHeight,
            CardFlight.landResponse,
            "пружина ширины длиннее оседания высоты — значит ширина приходит последней"
        )
        XCTAssertLessThan(CardFlight.landDamping, 1, "затухание неполное: одна волна перелёта есть")
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
