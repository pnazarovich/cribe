import AppKit
import SwiftUI
import TranscriberCore

/// Одна карточка — одно окно. Так стопка переживает свайпы между рабочими столами (каждое
/// окно само по себе `.canJoinAllSpaces`) и так же независимо анимируется: уход одной
/// карточки не заставляет пересобирать остальные.
@MainActor
final class CardPanel {
    let text: String

    /// Стопка убирает карточку из себя сама — панель лишь сообщает, что её больше нет.
    var onDismiss: ((CardPanel) -> Void)?

    /// Высота видимой карточки, без прозрачного запаса вокруг: по ней стопка считает раскладку.
    private(set) var cardHeight: CGFloat

    /// Появление — пружина с лёгким перелётом, как у пилюли: карточка выезжает слева и
    /// «садится» на место. Уход короче и без пружины.
    private static var appearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.38, dampingFraction: 0.72)
    }

    private static var disappearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion ? .easeInOut(duration: 0.16) : .easeIn(duration: 0.2)
    }

    /// Конец перелёта пилюли: карточка не выезжает, а проявляется ровно за то время, что
    /// летящая фигура растворяется. Оба конца шва идут одной длительностью — иначе он виден.
    private static var handoffAnimation: Animation {
        .easeOut(duration: CardFlight.handoff)
    }

    /// Окно живёт, пока карточка доигрывает уход: убрать его раньше — обрезать анимацию.
    /// Не private: на эту же паузу стопка откладывает приезд карточки, вытеснившей соседку.
    static let exitDuration: Duration = .milliseconds(240)
    /// Сколько держится вспышка «Скопировано».
    private static let copyFlash: Duration = .milliseconds(1200)
    /// Когда появление отыграно и тень можно пересчитать по готовому кадру.
    private static let appearSettle: Duration = .milliseconds(420)

    private let model: CardModel
    private let panel: NSPanel
    private let container: CardContainerView
    private var closeTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var isLeaving = false

    init(text: String) {
        self.text = text
        model = CardModel(text: text)

        let host = PassthroughHostingView(rootView: CardView(model: model))
        // Ширину задаёт сама карточка, высоту считает SwiftUI по числу строк текста.
        let size = host.fittingSize
        cardHeight = max(0, size.height - CardMetrics.bleed * 2)
        let frame = NSRect(origin: .zero, size: size)
        host.frame = frame
        host.autoresizingMask = [.width, .height]

        container = CardContainerView(frame: frame)
        container.cardHeight = cardHeight
        container.autoresizingMask = [.width, .height]
        container.addSubview(host)

        panel = NonActivatingCardPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Ярус и поведение — общий рецепт HUD (см. `HUDWindow`), тот же, что у пилюли.
        // Без `.stationary`: карточки обязаны ехать за пользователем между рабочими столами,
        // как скриншоты CleanShot, — на то они и «висят, пока не уберёшь».
        panel.level = HUDWindow.level
        panel.collectionBehavior = HUDWindow.spaceBehavior
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень рисует AppKit по альфе содержимого и СНАРУЖИ рамки окна — она не стоит ни
        // одного пикселя запаса и, главное, ни одного проглоченного клика. Своя тень в
        // SwiftUI красила бы прозрачный запас, а WindowServer маршрутизирует мышь по альфе:
        // полупрозрачный ореол ловил бы клики, не пропуская их в окно под карточкой.
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        // Карточка интерактивна — в отличие от пилюли, клики нужны ей самой.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = container

        container.model = model
        container.text = text
        // Масштаб — того экрана, на котором карточка окажется. Панель ещё не поставлена
        // на место, поэтому берём экран курсора: стопка выбирает его же.
        let scale = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?
            .backingScaleFactor ?? 2
        container.dragImage = Self.dragImage(text: text, cardHeight: cardHeight, scale: scale)
        container.onCopy = { [weak self] in self?.copy() }
        container.onClose = { [weak self] in self?.dismiss() }
        container.onSwipe = { [weak self] offset in self?.model.swipeOffset = offset }
        container.onSwipeEnded = { [weak self] dismissing in
            guard let self else { return }
            guard dismissing else {
                // Не дотянули: карточка возвращается на место пружиной.
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.model.swipeOffset = 0 }
                return
            }
            dismiss(swiped: true)
        }
        container.onDragBegan = { [weak self] in self?.model.isDragging = true }
        container.onDragEnded = { [weak self] accepted in
            guard let self else { return }
            model.isDragging = false
            // Текст приняли — карточка своё отработала. Отказ (`operation == []`) оставляет
            // её на месте: картинку AppKit сам возвращает в исходную точку.
            if accepted { dismiss() }
        }
    }

    /// Размер окна: карточка плюс прозрачный запас со всех сторон.
    var windowSize: NSSize {
        panel.frame.size
    }

    /// Картинка, которая поедет под курсором. Нужна тесту пропорций: сплющивание иначе
    /// ловится только глазом.
    var dragImageForTesting: NSImage? { container.dragImage }

    /// Видимый прямоугольник карточки на экране, без прозрачного запаса вокруг: в него
    /// целится перелёт капсулы.
    var cardFrameOnScreen: CGRect {
        CGRect(
            x: panel.frame.minX + CardMetrics.bleed,
            y: panel.frame.minY + CardMetrics.bleed,
            width: CardMetrics.width,
            height: cardHeight
        )
    }

    /// `fading` — карточка не выезжает слева, а проявляется на месте: так заканчивается
    /// перелёт пилюли, и шов между летящей фигурой и настоящей карточкой не виден.
    func present(fading: Bool = false) {
        // Заявка на «все пространства» подтверждается показом (см. `HUDWindow`).
        HUDWindow.orderFront(panel)
        model.entersByFading = fading
        withAnimation(fading ? Self.handoffAnimation : Self.appearAnimation) { model.isPresented = true }
        // Тень AppKit кэширует по альфе содержимого, а содержимое как раз приезжает —
        // без пересчёта после анимации она осталась бы от пустого кадра.
        Task { [panel] in
            try? await Task.sleep(for: Self.appearSettle)
            panel.invalidateShadow()
        }
    }

    /// Уход с анимацией и снятие окна следом. Повторный вызов (двойной клик по ✕, дроп
    /// на уже уходящей карточке) ничего не делает.
    ///
    /// `swiped` — карточку смахнули: она не гаснет на месте, а доезжает за левый край
    /// от того сдвига, где её отпустили. Прыжка на старое место при этом нет.
    func dismiss(swiped: Bool = false) {
        guard !isLeaving else { return }
        isLeaving = true
        if swiped, !HUDAccessibility.shared.reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                model.swipeOffset = -(CardMetrics.width + CardMetrics.bleed * 2)
            }
        }
        withAnimation(Self.disappearAnimation) { model.isPresented = false }
        // Ссылка на себя тут ОБЯЗАНА быть сильной. Вытесненная шестой карточка выпадает из
        // стопки последней ссылкой, и со слабой `self` задача просыпалась в пустоту: окно
        // при этом остаётся показанным (его держит список окон приложения) — то есть висит
        // на экране навсегда. Цикла нет: задача заканчивается и отпускает себя сама.
        closeTask = Task {
            try? await Task.sleep(for: Self.exitDuration)
            panel.orderOut(nil)
            onDismiss?(self)
        }
    }

    /// Левый нижний угол окна. Анимация — только на перекладку стопки: новая карточка
    /// ставится сразу на место и выезжает уже своим движением.
    func setOrigin(_ origin: NSPoint, animated: Bool) {
        guard animated, !HUDAccessibility.shared.reduceMotion else {
            panel.setFrameOrigin(origin)
            return
        }
        let target = NSRect(origin: origin, size: panel.frame.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            // Лёгкий перелёт в конце: то же ощущение пружины, что у появления пилюли.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.06)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [panel] in
            // Переезд окна тень не пересчитывает — после него она осталась бы от старого места.
            panel.invalidateShadow()
        }
    }

    private func copy() {
        TextInserter.copy(text)
        copyTask?.cancel()
        model.didCopy = true
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copyFlash)
            guard !Task.isCancelled else { return }
            self?.model.didCopy = false
        }
    }

    /// Картинка под курсором. Рисуем её один раз при создании карточки: во время самого
    /// перетаскивания рендерить уже поздно.
    ///
    /// Габарит задаётся ЖЁСТКО — ровно та карточка, что на экране, плюс поле под тень.
    /// Иначе картинка выходит своей высоты (в превью нет шапки), AppKit растягивает её
    /// в переданный кадр, и карточка под курсором сплющивается. Пропорция картинки и кадра
    /// обязана совпадать — это и проверяет тест.
    private static func dragImage(text: String, cardHeight: CGFloat, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(
            content: CardDragPreview(text: text, height: cardHeight)
        )
        // Масштаб экрана самой карточки: на Retina картинка иначе была бы мыльной.
        renderer.scale = scale
        return renderer.nsImage
    }

    /// Кадр летящей под курсором картинки: карточка плюс поле под тень и лёгкое увеличение —
    /// стандартный намёк «предмет оторвался от стола». Пропорции при этом не меняются:
    /// множитель один на обе стороны, поле одинаково со всех сторон.
    static func dragFrame(cardRect: CGRect) -> CGRect {
        let withShadow = cardRect.insetBy(dx: -CardMetrics.dragShadow, dy: -CardMetrics.dragShadow)
        // Увеличение вокруг центра: обе стороны умножаются на одно число, поэтому
        // пропорция картинки и кадра остаётся общей.
        let grow = CardMetrics.dragScale - 1
        return withShadow.insetBy(
            dx: -withShadow.width * grow / 2,
            dy: -withShadow.height * grow / 2
        )
    }
}

/// `canBecomeKey` / `canBecomeMain` у NSWindow только для чтения — отключаются переопределением.
/// Ключевой инвариант тот же, что у пилюли: окно не должно забирать фокус у целевого поля.
private final class NonActivatingCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Тело карточки мышь не ловит вовсе: наведение, клики и перетаскивание ведёт контейнер.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Мышь карточки целиком на AppKit.
///
/// Причина простая: панель никогда не становится key, а приложение почти всегда неактивно —
/// в таком окне SwiftUI-кнопки и `.onHover` срабатывают через раз (первый клик съедается,
/// трекинг живёт только у активного приложения). Контейнер же сам раскладывает карточку,
/// поэтому попадание в кнопки считает точно, а трекинг ставит с `.activeAlways`.
private final class CardContainerView: NSView, NSDraggingSource {
    var model: CardModel?
    var text = ""
    var dragImage: NSImage?
    var cardHeight: CGFloat = 0

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    /// Текущий сдвиг под пальцами.
    var onSwipe: ((CGFloat) -> Void)?
    /// Жест закончился: `true` — карточку смахнули, `false` — вернуть на место.
    var onSwipeEnded: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    /// `true` — текст приняли; `false` — бросили в пустоту, карточка остаётся.
    var onDragEnded: ((Bool) -> Void)?

    /// Дальше этого сдвига нажатие считается перетаскиванием, а не кликом.
    private static let dragThreshold: CGFloat = 3

    private var trackingArea: NSTrackingArea?
    private var pressedControl: CardControl?
    private var downPoint: NSPoint?
    private var isDragging = false
    /// Идёт смахивание: путь пальцев с начала жеста и последняя дельта (она же скорость,
    /// потому что события приходят ровным потоком).
    private var swipeTravel: CGFloat?
    private var swipeSpeed: CGFloat = 0

    /// Совпадает со SwiftUI: начало координат слева сверху.
    override var isFlipped: Bool { true }

    /// Приложение неактивно, окно не key — каждый клик по карточке «первый».
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Видимая карточка внутри окна; вокруг неё прозрачный запас под тень.
    private var cardRect: CGRect {
        CGRect(
            x: CardMetrics.bleed,
            y: CardMetrics.bleed,
            width: CardMetrics.width,
            height: cardHeight
        )
    }

    /// Клики мимо карточки (в прозрачный запас) должны доходить до окна под ней.
    override func hitTest(_ point: NSPoint) -> NSView? {
        cardRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: cardRect,
            // `.activeAlways` — иначе наведение работало бы только у активного приложения,
            // а карточка живёт как раз поверх чужих окон.
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Наведение

    override func mouseEntered(with event: NSEvent) {
        model?.isHovered = true
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        model?.isHovered = false
        model?.hoveredControl = nil
        NSCursor.arrow.set()
    }

    private func updateHover(at point: NSPoint) {
        let control = self.control(at: point)
        model?.hoveredControl = control
        // Раскрытая ладонь над телом карточки — стандартный намёк «это можно тащить».
        (control == nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    private func control(at point: NSPoint) -> CardControl? {
        let local = CGPoint(x: point.x - CardMetrics.bleed, y: point.y - CardMetrics.bleed)
        if CardMetrics.controlRect(.close).contains(local) { return .close }
        if CardMetrics.controlRect(.copy).contains(local) { return .copy }
        return nil
    }

    // MARK: - Клики и перетаскивание

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        pressedControl = control(at: point)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        // Начатое на кнопке движение — не перетаскивание: кнопку либо нажмут, либо уедут с неё.
        // Идущее смахивание перетаскивание тоже не начинает: два жеста разом — это рывок
        // картинки посреди смахивания.
        guard !isDragging, pressedControl == nil, swipeTravel == nil, let downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) > Self.dragThreshold else { return }
        isDragging = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downPoint = nil
            pressedControl = nil
        }
        guard !isDragging, let pressedControl else { return }
        // Нажали и отпустили на одной кнопке — как у обычной кнопки AppKit.
        guard control(at: convert(event.locationInWindow, from: nil)) == pressedControl else { return }
        switch pressedControl {
        case .copy: onCopy?()
        case .close: onClose?()
        }
    }

    // MARK: - Смахивание двумя пальцами

    /// Двумя пальцами влево — карточка уходит.
    ///
    /// Знак замерен на живой системе: при естественной прокрутке (значение по умолчанию)
    /// пальцы влево дают `scrollingDeltaX < 0` — та же дельта, с которой содержимое любого
    /// NSScrollView едет влево вместе с пальцами. Поэтому сдвиг просто копит дельту.
    ///
    /// Мышиное колесо жестом не считается (`hasPreciseScrollingDeltas`), инерционный хвост
    /// после отпускания — тоже: карточка не должна уезжать сама, когда пальцы уже сняты.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [], !isDragging else {
            super.scrollWheel(with: event)
            return
        }
        switch event.phase {
        case .began:
            swipeTravel = 0
            swipeSpeed = 0
        case .changed:
            // Поток бывает и без `.began` (жест начался за пределами карточки) — тогда
            // считаем от первого же события: пропустить смахивание хуже, чем начать позже.
            let travel = (swipeTravel ?? 0) + event.scrollingDeltaX
            swipeTravel = travel
            swipeSpeed = event.scrollingDeltaX
            onSwipe?(CardSwipe.offset(forFingerTravel: travel, width: CardMetrics.width))
        case .ended, .cancelled:
            guard let travel = swipeTravel else { return }
            swipeTravel = nil
            let offset = CardSwipe.offset(forFingerTravel: travel, width: CardMetrics.width)
            onSwipeEnded?(
                event.phase == .cancelled
                    ? false
                    : CardSwipe.dismisses(offset: offset, speed: swipeSpeed, width: CardMetrics.width)
            )
        default:
            break
        }
    }

    private func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        let dragged = NSDraggingItem(pasteboardWriter: item)
        // Кадр считается ровно по картинке (см. `CardPanel.dragFrame`): любое расхождение
        // пропорций AppKit исправит растяжением — карточка поедет сплющенной.
        dragged.setDraggingFrame(CardPanel.dragFrame(cardRect: cardRect), contents: dragImage)

        let session = beginDraggingSession(with: [dragged], event: event, source: self)
        // Не приняли — картинка возвращается на карточку сама, без нашего участия.
        session.animatesToStartingPositionsOnCancelOrFail = true
        onDragBegan?()
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Внутри своего приложения ронять некуда — принимают только чужие поля ввода.
        context == .outsideApplication ? [.copy, .generic] : []
    }

    /// Модификаторы не должны превращать копию в ссылку или перемещение.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        downPoint = nil
        pressedControl = nil
        // Курсор уехал вместе с картинкой и обратно уже не «войдёт» — трекинг события входа
        // не пришлёт. Без сброса отказавшаяся карточка навсегда осталась бы подсвеченной.
        model?.isHovered = false
        model?.hoveredControl = nil
        // Пустая маска — единственный надёжный признак «никто не взял»: конкретную операцию
        // приёмник выбирает сам (кто-то отвечает `.copy`, кто-то `.generic`).
        onDragEnded?(operation != [])
    }
}
