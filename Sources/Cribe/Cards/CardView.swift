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
    /// Насколько подпись в шапке ниже верха строки: строка ростом с кнопку (22), подпись —
    /// с собственный кегль (10 pt, строка ≈ 12), и разница делится поровну сверху и снизу.
    static let headerSlack: CGFloat = 5
    /// Дальше текст не растёт: полный лежит в самой карточке и уезжает при перетаскивании.
    static let lineLimit = 4
    /// Сдвиг влево на входе и уходе: карточка выезжает из-за левого края экрана.
    static let slide: CGFloat = 16
    /// Поле вокруг картинки, которую тащат: в нём живёт тень оторвавшейся карточки.
    static let dragShadow: CGFloat = 10
    /// Лёгкое увеличение под курсором — предмет «оторвался от стола». Одинаково по обеим
    /// сторонам: перекос множителей и есть та самая сплюснутость.
    static let dragScale: CGFloat = 1.02

    /// Кнопки в шапке, справа налево. Система координат — карточка, начало слева сверху.
    static func controlRect(_ control: CardControl) -> CGRect {
        let column: CGFloat
        switch control {
        case .close: column = 0
        case .copy: column = 1
        case .translate: column = 2
        case .expand: column = 3
        }
        return CGRect(
            x: width - padding - (self.control + controlGap) * column - self.control,
            // Та же поправка, что и у шапки: кнопки уехали вверх вместе с ней, и зона
            // клика обязана уехать ровно настолько же.
            y: padding - headerSlack,
            width: self.control,
            height: self.control
        )
    }
}

/// Кнопки карточки при наведении. Порядок — слева направо, как они и стоят в шапке.
enum CardControl: Equatable, CaseIterable {
    /// Текст целиком: карточка держит четыре строки, а вся диктовка живёт в окне истории.
    case expand
    case translate
    case copy
    case close
}

/// Состояние одной карточки. Меняет его AppKit-контейнер (он ведёт мышь), читает SwiftUI.
@MainActor
final class CardModel: ObservableObject {
    /// Диктовка как она есть. Перевод, если его просили, ложится рядом и остаётся здесь:
    /// переключение «оригинал ↔ перевод» второй раз в сеть не ходит.
    let text: String
    private(set) var translation: String?

    /// Показывается перевод, а не оригинал.
    @Published private(set) var showsTranslation = false
    /// Идёт запрос перевода.
    @Published private(set) var isTranslating = false
    /// Короткая жалоба под текстом; карточка при этом остаётся с оригиналом.
    @Published private(set) var failure: String?
    /// Подмена текста: он размывается, меняется и наводится на резкость обратно.
    @Published private(set) var isSwapping = false
    /// Толчок вбок на неудаче — единственный способ сказать «не вышло» на карточке.
    @Published private(set) var shake: CGFloat = 0

    /// Что сейчас НА карточке: этот текст и копируется, и уезжает перетаскиванием.
    var displayText: String {
        showsTranslation ? (translation ?? text) : text
    }

    /// Перевод уже есть — значит, кнопка возвращает к оригиналу, а не идёт в сеть.
    var hasTranslation: Bool { translation != nil }

    /// Доступен ли перевод вообще: без GPT переводить нечем. Ставит владелец карточки.
    var canTranslate = true

    /// Карточка на месте: вход отыгран, уход ещё не начался. Ведёт и появление, и уход.
    @Published var isPresented = false
    @Published var isHovered = false
    @Published var hoveredControl: CardControl?
    @Published var isDragging = false
    /// Вспышка «Скопировано» вместо подписи в шапке.
    @Published var didCopy = false
    /// Карточка приехала не сама, а перелётом пилюли: тогда она проявляется на месте,
    /// без выезда слева — иначе на стыке видно, как содержимое «дёргается».
    @Published var entersByFading = false
    /// Сдвиг под пальцами при смахивании: карточка идёт за жестом, а не прыгает по нему.
    @Published var swipeOffset: CGFloat = 0

    init(text: String) {
        self.text = text
    }

    // MARK: - Перевод

    /// Запрос начался: кнопка крутит спиннер, прежняя жалоба снимается.
    func beganTranslating() {
        isTranslating = true
        failure = nil
    }

    /// Перевод приехал: он запоминается и показывается сменой текста через размытие.
    func apply(translation: String) {
        self.translation = translation
        isTranslating = false
        swap(toTranslation: true)
    }

    /// Переключение уже полученного перевода туда-обратно — без единого запроса.
    func toggleTranslation() {
        guard translation != nil else { return }
        swap(toTranslation: !showsTranslation)
    }

    /// Не вышло: карточка оставляет оригинал, дёргается вбок и коротко жалуется.
    func failedTranslating() {
        isTranslating = false
        failure = "не удалось перевести"
        guard !HUDAccessibility.shared.reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.06).repeatCount(4, autoreverses: true)) { shake = 5 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            shake = 0
        }
    }

    /// Подмена текста «сквозь размытие»: буквы не подменяются рывком, а расплываются
    /// и наводятся на резкость уже другими.
    private func swap(toTranslation: Bool) {
        guard !HUDAccessibility.shared.reduceMotion else {
            showsTranslation = toTranslation
            return
        }
        withAnimation(.easeIn(duration: 0.12)) { isSwapping = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            showsTranslation = toTranslation
            withAnimation(.easeOut(duration: 0.18)) { isSwapping = false }
        }
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
            Text(model.displayText)
                .font(.system(size: 12))
                .lineLimit(CardMetrics.lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.92))
                // Стекло почти прозрачное: без микротени буквы плывут над светлым фоном.
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                // Подмена на перевод идёт сквозь размытие: буквы расплываются и наводятся
                // на резкость уже другими.
                .blur(radius: model.isSwapping ? 5 : 0)
                .opacity(model.isSwapping ? 0.25 : 1)
            if let failure = model.failure {
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .transition(.opacity)
            }
        }
        .padding(CardMetrics.padding)
        // Сверху отступ меньше на просвет, который шапка добавляет сама: подпись ростом
        // с текст, а строка держит высоту круглой кнопки и центрирует подпись в ней.
        // Без поправки воздуха над подписью заметно больше, чем под текстом.
        .padding(.top, -CardMetrics.headerSlack)
        // Толчок вбок — жалоба на неудавшийся перевод.
        .offset(x: model.shake)
        .animation(.easeOut(duration: 0.2), value: model.failure)
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
        // Вход и уход одним движением: выезжает слева, уходит туда же. После перелёта
        // пилюли — только проявление: ехать карточке неоткуда, она уже «прилетела».
        // Сдвиг смахивания складывается с этим: жест продолжается тем же движением, каким
        // карточка и уходит.
        .offset(x: (model.isPresented || model.entersByFading ? 0 : -CardMetrics.slide) + model.swipeOffset)
        .opacity(model.isPresented ? CardSwipe.opacity(offset: model.swipeOffset, width: CardMetrics.width) : 0)
        // Схема фиксированно тёмная: только она читается над любым фоном.
        .environment(\.colorScheme, .dark)
        .padding(CardMetrics.bleed)
    }

    /// Шапка держит высоту всегда: кнопки появляются на наведении, но место под них
    /// зарезервировано — иначе текст прыгал бы под курсором.
    private var header: some View {
        HStack(spacing: 6) {
            // Краб крупнее подписи рядом: силуэт с полосами и ногами в десяти точках
            // сливается в пятно, а системный символ волны читался и в них.
            CrabGlyph(height: 12)
            Text(label)
                .font(.system(size: 10, weight: .medium))
            if model.showsTranslation {
                // Метка «на карточке уже перевод»: без неё английский текст на месте
                // русского выглядит так, будто диктовка распозналась не тем языком.
                Text("→ EN")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: Capsule())
            }
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
        if model.isTranslating { return "Перевожу…" }
        // Подсказка к кнопке под курсором. Обычных всплывающих подсказок (`help`) у карточки
        // нет и быть не может: контролы ведёт AppKit, панель никогда не становится key, —
        // поэтому подпись в шапке и есть единственное место, где можно сказать, что делает
        // кнопка. Раньше так объяснялась одна «развернуть», а остальные три молчали.
        if let control = model.hoveredControl { return hint(for: control) }
        return model.isHovered ? "Перетащите в поле ввода" : "Cribe"
    }

    private func hint(for control: CardControl) -> String {
        switch control {
        case .expand: return "Посмотреть целиком"
        case .translate: return model.showsTranslation ? "Вернуть оригинал" : "Перевести на английский"
        case .copy: return "Скопировать"
        case .close: return "Убрать карточку"
        }
    }

    private var controls: some View {
        HStack(spacing: CardMetrics.controlGap) {
            controlButton(.expand, symbol: "arrow.up.left.and.arrow.down.right")
            translateButton
            controlButton(.copy, symbol: "doc.on.doc")
            controlButton(.close, symbol: "xmark")
        }
    }

    /// Перевод: глобус — «перевести», стрелка — «вернуть оригинал», спиннер — «идёт».
    /// Без GPT кнопка приглушена: нажимать её незачем, но и прятать нельзя — иначе
    /// непонятно, что перевод вообще бывает.
    @ViewBuilder
    private var translateButton: some View {
        if model.isTranslating {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: CardMetrics.control, height: CardMetrics.control)
        } else {
            controlButton(
                .translate,
                symbol: model.showsTranslation ? "arrow.uturn.backward" : "globe",
                dimmed: !model.canTranslate
            )
        }
    }

    /// Не `Button`: клики принимает контейнер — панель никогда не становится key, и полагаться
    /// на SwiftUI-жесты в чужом активном приложении нельзя. Здесь только вид и подсветка.
    private func controlButton(_ control: CardControl, symbol: String, dimmed: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(dimmed ? 0.35 : 0.9))
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
///
/// Высота приходит снаружи и равна высоте карточки на экране. Своей высоты у превью быть
/// не должно: в нём нет шапки, оно вышло бы ниже карточки, AppKit растянул бы картинку
/// в переданный кадр — и предмет под курсором сплющился бы по горизонтали.
struct CardDragPreview: View {
    let text: String
    let height: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .lineLimit(CardMetrics.lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(CardMetrics.padding)
            .frame(width: CardMetrics.width, height: height, alignment: .topLeading)
            .background(
                Color(white: 0.16).opacity(0.92),
                in: RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            // Тень оторвавшегося предмета живёт в поле вокруг картинки, поэтому габарит
            // и растёт на `dragShadow` с каждой стороны.
            .shadow(color: .black.opacity(0.45), radius: CardMetrics.dragShadow * 0.6, y: 2)
            .padding(CardMetrics.dragShadow)
            .environment(\.colorScheme, .dark)
    }
}
