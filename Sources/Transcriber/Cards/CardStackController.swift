import AppKit

/// Стопка карточек у нижнего левого угла экрана: новая приезжает к самому низу, прежние
/// уезжают вверх; когда одна уходит, оставшиеся оседают на её место.
@MainActor
final class CardStackController {
    /// Больше пяти карточек на экране — уже свалка. Самая старая уходит молча: текст при этом
    /// не теряется, он лежит в истории — её конвейер пишет на каждой диктовке, включая эту.
    private static let limit = 5

    /// Снизу вверх: нулевая — самая свежая, у самого низа экрана.
    private var cards: [CardPanel] = []

    /// Экран, на котором живёт стопка. Выбирается по курсору при появлении первой карточки —
    /// как и у панели диктовки. Пока стопка не опустела, она никуда не переезжает: разъезжаться
    /// по мониторам вслед за мышью карточки не должны.
    private var screenFrame: CGRect?

    func push(_ text: String) {
        if cards.isEmpty { screenFrame = Self.cursorScreenFrame() }
        guard screenFrame != nil else { return }

        let card = CardPanel(text: text)
        card.onDismiss = { [weak self] card in self?.remove(card) }
        cards.insert(card, at: 0)
        // Лишние снимаем до раскладки: анимировать уезжающие вверх карточки, которых через
        // мгновение не станет, незачем.
        while cards.count > Self.limit {
            cards.removeLast().dismiss()
        }

        // Новая карточка встаёт на своё место сразу: ехать ей неоткуда, она выезжает
        // собственной анимацией слева. Двигаются только те, что уже висели.
        layout(animated: true, placing: card)
        card.present()
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
    private static func cursorScreenFrame() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return screen?.visibleFrame
    }
}
