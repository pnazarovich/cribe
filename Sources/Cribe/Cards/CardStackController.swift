import AppKit

/// Стопка карточек у нижнего левого угла экрана: новая приезжает к самому низу, прежние
/// уезжают вверх; когда одна уходит, оставшиеся оседают на её место.
@MainActor
final class CardStackController {
    /// Десять карточек в ряд — верхний предел, дальше это уже свалка. Самая старая уходит
    /// молча: текст при этом не теряется, он лежит в истории — её конвейер пишет на каждой
    /// диктовке, включая эту.
    private static let limit = 10

    /// Снизу вверх: нулевая — самая свежая, у самого низа экрана.
    private var cards: [CardPanel] = []

    /// Откуда стопка узнаёт свой экран. По умолчанию — курсор; тест подставляет свой
    /// прямоугольник, иначе «влезает ли десять карточек» зависело бы от монитора машины.
    private let screenProvider: @MainActor () -> CGRect?

    /// Откуда карточки берут перевод: стопка его не делает, только передаёт.
    private let translator: CardTranslator

    /// Куда карточки уводят по «посмотреть целиком»: стопка и тут только передаёт.
    private let onExpand: @MainActor (String) -> Void

    init(
        screenProvider: @escaping @MainActor () -> CGRect? = CardStackController.cursorScreenFrame,
        translator: CardTranslator = .unavailable,
        onExpand: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.screenProvider = screenProvider
        self.translator = translator
        self.onExpand = onExpand
    }

    /// Экран, на котором живёт стопка.
    ///
    /// Замысел: монитор выбирается один раз — когда стопка заводится с нуля, по курсору
    /// (там же, где и окно, в которое диктовали). Пока карточки висят, следующая
    /// присоединяется к ним на том же экране, а уже висящие не переезжают НИКОГДА:
    /// стопка, скачущая между мониторами вслед за мышью, — это потерянные карточки.
    private var screenFrame: CGRect?

    /// Сколько карточек стопка считает своими. Нужен пробе и тесту вытеснения.
    var count: Int { cards.count }

    /// Одну из карточек сейчас тащат.
    ///
    /// На это время ВСЯ стопка становится сквозной для мыши. Причина в том, что наши окна
    /// стоят на ярусе `.statusBar` — выше окна-приёмника — и в нижнем левом углу экрана,
    /// там же, где поле ввода мессенджера. Карточка, накрывшая точку сброса (своя же или
    /// соседняя по стопке), забирает сброс себе, а принять его не может: дропы мы нигде
    /// не регистрируем. Снаружи это и выглядит как «перетаскивание иногда не срабатывает».
    private(set) var isDragInProgress = false

    /// Единственный инвариант стопки: карточек не больше потолка И вся пачка вместе с
    /// просветами и полями по краям помещается в высоту экрана. На низком мониторе (или на
    /// длинных многострочных карточках) реальный предел — «сколько влезает», а не десять.
    ///
    /// Нарушение проверяется на каждой вставке; одну карточку не вытесняем никогда —
    /// даже если она сама выше экрана, показать её лучше, чем не показать ничего.
    var fitsOnScreen: Bool {
        guard let screenFrame else { return true }
        guard cards.count <= Self.limit else { return false }
        return stackedHeight <= screenFrame.height
    }

    /// Высота всей стопки: карточки, просветы между ними и одинаковые поля снизу и сверху.
    var stackedHeight: CGFloat {
        let heights = cards.reduce(0) { $0 + $1.cardHeight }
        let gaps = CardMetrics.gap * CGFloat(max(0, cards.count - 1))
        return CardMetrics.screenInset * 2 + heights + gaps
    }

    /// Самая свежая карточка — та, что у самого низа экрана. Нужна тесту перетаскивания:
    /// настоящий жест в прогоне не завести, поэтому тест дёргает карточку напрямую.
    var topCardForTesting: CardPanel? { cards.first }

    /// Убирает всё с экрана — нужен тесту, чтобы прогон не оставлял за собой окон.
    func dismissAllForTesting() {
        for card in cards { card.dismiss() }
    }

    /// `false` — показать карточку не вышло (не нашли экрана): вызывающий обязан вставить
    /// текст обычным путём, иначе диктовка молча пропадёт.
    ///
    /// `flyingFrom` — кадр капсулы HUD: если он есть, карточка не выезжает слева, а
    /// прилетает из капсулы (та по дороге превращается в её силуэт).
    @discardableResult
    func push(_ text: String, flyingFrom source: CGRect? = nil) -> Bool {
        // Новая стопка — новый монитор; у живой стопки экран не трогаем (см. `screenFrame`).
        if cards.isEmpty { screenFrame = screenProvider() }
        guard screenFrame != nil else { return false }

        let card = CardPanel(text: text, translator: translator, onExpand: onExpand)
        card.onDismiss = { [weak self] card in self?.remove(card) }
        card.onDragStateChanged = { [weak self] dragging in self?.setDragInProgress(dragging) }
        // Диктовка, доехавшая посреди жеста, не имеет права проломить инвариант: новая
        // карточка встаёт в стопку такой же сквозной, как и остальные.
        card.setTransparentToDrag(isDragInProgress)
        cards.insert(card, at: 0)

        // Инвариант проверяем прямо здесь и безусловно. Отложить проверку нельзя: две
        // диктовки подряд попадали бы обе в «стопка ещё не полна», и отложенная вставка
        // выносила бы стопку за предел. Держится на каждой вставке, а не когда-нибудь потом.
        var evicted = false
        while !fitsOnScreen, cards.count > 1 {
            cards.removeLast().dismiss()
            evicted = true
        }

        guard evicted else {
            // Новая карточка встаёт на своё место сразу: ехать ей неоткуда, она выезжает
            // собственной анимацией слева. Двигаются только те, что уже висели.
            layout(animated: true, placing: card)
            present(card, flyingFrom: source)
            return true
        }
        // Вытесненной надо дать уйти: иначе оставшиеся наезжают на неё по дороге вверх.
        // Учёт при этом уже закончен — ждёт только картинка.
        Task { [weak self] in
            try? await Task.sleep(for: CardPanel.exitDuration)
            guard let self, cards.contains(where: { $0 === card }) else { return }
            layout(animated: true, placing: card)
            // Перелёт ждать не заставляем: капсула к этому моменту уже отработала своё,
            // и фигура, стартующая из пустоты, выглядела бы призраком.
            present(card, flyingFrom: nil)
        }
        return true
    }

    /// Показ новой карточки: сама выезжает слева — или её приносит перелёт капсулы,
    /// и тогда она лишь проявляется в точке приземления.
    private func present(_ card: CardPanel, flyingFrom source: CGRect?) {
        guard let source else {
            card.present()
            return
        }
        CardFlight.fly(from: source, to: card.cardFrameOnScreen) { [weak card] in
            card?.present(fading: true)
        }
    }

    /// Начало и конец жеста: состояние держится на стопке, а не на карточке, потому что
    /// мешает сбросу вся стопка целиком, а не только та карточка, которую тащат.
    private func setDragInProgress(_ dragging: Bool) {
        isDragInProgress = dragging
        for card in cards { card.setTransparentToDrag(dragging) }
    }

    private func remove(_ card: CardPanel) {
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: index)
        if cards.isEmpty { screenFrame = nil }
        layout(animated: true)
    }

    /// Раскладка снизу вверх. Координата — левый нижний угол окна, поэтому от видимой
    /// позиции карточки отнимается прозрачный запас вокруг неё.
    private func layout(animated: Bool, placing newcomer: CardPanel? = nil) {
        guard let screenFrame else { return }
        let x = (screenFrame.minX + CardMetrics.screenInset - CardMetrics.bleed).rounded()
        var bottom = screenFrame.minY + CardMetrics.screenInset

        for card in cards {
            card.setOrigin(
                NSPoint(x: x, y: (bottom - CardMetrics.bleed).rounded()),
                animated: animated && card !== newcomer
            )
            bottom += card.cardHeight + CardMetrics.gap
        }
    }

    /// Экран под курсором — там же, где и окно, в которое диктовали. `visibleFrame`,
    /// а не `frame`: карточки не должны прятаться под Dock.
    static func cursorScreenFrame() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen?.visibleFrame
    }
}
