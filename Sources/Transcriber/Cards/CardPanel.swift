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
        // Ярус HUD, тот же, что у панели диктовки: `.floating` (3) перекрывается окнами
        // приложений в режиме презентации и полноэкранного видео, а `.statusBar` (25) — нет.
        // Рецепт живой панели проверен полным экраном в бою, поэтому карточки носят его же.
        panel.level = .statusBar
        // Без `.stationary`: карточки обязаны ехать за пользователем между рабочими столами,
        // как скриншоты CleanShot, — на то они и «висят, пока не уберёшь».
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        container.dragImage = Self.dragImage(text: text)
        container.onCopy = { [weak self] in self?.copy() }
        container.onClose = { [weak self] in self?.dismiss() }
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

    func present() {
        // Именно `orderFrontRegardless`: makeKey увёл бы фокус с целевого поля.
        panel.orderFrontRegardless()
        withAnimation(Self.appearAnimation) { model.isPresented = true }
        // Тень AppKit кэширует по альфе содержимого, а содержимое как раз приезжает —
        // без пересчёта после анимации она осталась бы от пустого кадра.
        Task { [panel] in
            try? await Task.sleep(for: Self.appearSettle)
            panel.invalidateShadow()
        }
    }

    /// Уход с анимацией и снятие окна следом. Повторный вызов (двойной клик по ✕, дроп
    /// на уже уходящей карточке) ничего не делает.
    func dismiss() {
        guard !isLeaving else { return }
        isLeaving = true
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
    private static func dragImage(text: String) -> NSImage? {
        let renderer = ImageRenderer(content: CardDragPreview(text: text))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
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
    var onDragBegan: (() -> Void)?
    /// `true` — текст приняли; `false` — бросили в пустоту, карточка остаётся.
    var onDragEnded: ((Bool) -> Void)?

    /// Дальше этого сдвига нажатие считается перетаскиванием, а не кликом.
    private static let dragThreshold: CGFloat = 3

    private var trackingArea: NSTrackingArea?
    private var pressedControl: CardControl?
    private var downPoint: NSPoint?
    private var isDragging = false

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
        guard !isDragging, pressedControl == nil, let downPoint else { return }
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

    private func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        let dragged = NSDraggingItem(pasteboardWriter: item)
        dragged.setDraggingFrame(cardRect, contents: dragImage)

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
