import SwiftUI

/// Габариты карточки. Живут отдельно, потому что их знают двое: SwiftUI, который карточку
/// рисует, и AppKit-контейнер, который по этим же числам считает попадание мыши в кнопки.
/// Разъехаться им нельзя — отсюда одно место с числами, а не два набора констант.
enum CardMetrics {
    static let width: CGFloat = 300
    /// Отступ стопки от углов экрана.
    static let screenInset: CGFloat = 16
    /// Просвет между карточками.
    static let gap: CGFloat = 8
    /// Прозрачный запас вокруг карточки внутри окна: в нём живут мягкая тень и вылет
    /// анимации входа. Окно чуть больше карточки, лишнее не видно.
    static let bleed: CGFloat = 24
    static let corner: CGFloat = 14
    static let padding: CGFloat = 12
    /// Сторона круглой кнопки в шапке.
    static let control: CGFloat = 22
    static let controlGap: CGFloat = 6
    /// Дальше текст не растёт: полный лежит в самой карточке и уезжает при перетаскивании.
    static let lineLimit = 4
    /// Сдвиг влево на входе и уходе: карточка выезжает из-за левого края экрана.
    static let slide: CGFloat = 16

    /// Кнопки в шапке, справа налево. Система координат — карточка, начало слева сверху.
    static func controlRect(_ control: CardControl) -> CGRect {
        let column: CGFloat = control == .close ? 0 : 1
        return CGRect(
            x: width - padding - (self.control + controlGap) * column - self.control,
            y: padding,
            width: self.control,
            height: self.control
        )
    }
}

/// Кнопки карточки при наведении.
enum CardControl: Equatable {
    case copy
    case close
}

/// Состояние одной карточки. Меняет его AppKit-контейнер (он ведёт мышь), читает SwiftUI.
@MainActor
final class CardModel: ObservableObject {
    let text: String

    /// Карточка на месте: вход отыгран, уход ещё не начался. Ведёт и появление, и уход.
    @Published var isPresented = false
    @Published var isHovered = false
    @Published var hoveredControl: CardControl?
    @Published var isDragging = false
    /// Вспышка «Скопировано» вместо подписи в шапке.
    @Published var didCopy = false

    init(text: String) {
        self.text = text
    }
}

/// Карточка диктовки: стекло, текст и две кнопки в шапке. Мышь сюда не доходит вовсе —
/// хост-вью не участвует в hit-тесте, всё ведёт `CardContainerView`.
struct CardView: View {
    @ObservedObject var model: CardModel

    @ObservedObject private var accessibility = HUDAccessibility.shared

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(model.text)
                .font(.system(size: 12))
                .lineLimit(CardMetrics.lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.92))
                // Стекло почти прозрачное: без микротени буквы плывут над светлым фоном.
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        .padding(CardMetrics.padding)
        .frame(width: CardMetrics.width, alignment: .leading)
        .background { GlassPlate(shape: shape, cornerRadius: CardMetrics.corner) }
        .overlay { GlassRim(shape: shape) }
        .overlay { GlassSheen(shape: shape) }
        .overlay { if !accessibility.reduceMotion { SpecularSweep(shape: shape) } }
        // Без группировки эффекты считались бы от каждого сабвью отдельно.
        .compositingGroup()
        // Тени тут нет намеренно: её рисует окно (`panel.hasShadow`). Своя тень красила бы
        // прозрачный запас вокруг карточки, а мышь WindowServer маршрутизирует по альфе —
        // полупрозрачный ореол ловил бы клики, не пропуская их в окно под карточкой.
        // Пока карточку тащат, оригинал слегка отступает: тянут «её», а не копию.
        .opacity(model.isDragging ? 0.35 : 1)
        .scaleEffect(model.isDragging ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: model.isDragging)
        // Вход и уход одним движением: выезжает слева, уходит туда же.
        .offset(x: model.isPresented ? 0 : -CardMetrics.slide)
        .opacity(model.isPresented ? 1 : 0)
        // Схема фиксированно тёмная: только она читается над любым фоном.
        .environment(\.colorScheme, .dark)
        .padding(CardMetrics.bleed)
    }

    /// Шапка держит высоту всегда: кнопки появляются на наведении, но место под них
    /// зарезервировано — иначе текст прыгал бы под курсором.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 4)
            controls.opacity(model.isHovered ? 1 : 0)
        }
        .foregroundStyle(model.didCopy ? Color.green : .white.opacity(0.55))
        .frame(height: CardMetrics.control)
        .animation(.easeOut(duration: 0.15), value: model.isHovered)
        .animation(.easeOut(duration: 0.15), value: model.didCopy)
    }

    /// Подсказка про перетаскивание живёт на наведении: это единственное место, где о ней
    /// вообще можно рассказать, и она же объясняет, зачем карточка нужна.
    private var label: String {
        if model.didCopy { return "Скопировано" }
        return model.isHovered ? "Перетащите в поле ввода" : "Диктовка"
    }

    private var controls: some View {
        HStack(spacing: CardMetrics.controlGap) {
            controlButton(.copy, symbol: "doc.on.doc")
            controlButton(.close, symbol: "xmark")
        }
    }

    /// Не `Button`: клики принимает контейнер — панель никогда не становится key, и полагаться
    /// на SwiftUI-жесты в чужом активном приложении нельзя. Здесь только вид и подсветка.
    private func controlButton(_ control: CardControl, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: CardMetrics.control, height: CardMetrics.control)
            .background(
                // Плоская подложка, не второй материал: стекло на стекле выглядит дёшево.
                .white.opacity(model.hoveredControl == control ? 0.22 : 0.10),
                in: Circle()
            )
    }
}

/// Картинка, которая летит за курсором: системный материал в неё не попадает (его рисует
/// WindowServer), поэтому подложка здесь сплошная. Форма и текст — те же, что у карточки.
struct CardDragPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .lineLimit(CardMetrics.lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(CardMetrics.padding)
            .frame(width: CardMetrics.width, alignment: .leading)
            .background(
                Color(white: 0.16).opacity(0.92),
                in: RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .environment(\.colorScheme, .dark)
    }
}
