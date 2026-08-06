import AppKit
import SwiftUI
import CribeCore

/// Содержимое живой панели: одна маленькая пилюля у нижнего края экрана.
/// Пересобирается на каждое обновление уровня (~12 раз в секунду), поэтому дерево держим плоским.
struct PanelView: View {
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        Group {
            // Видимость ведёт LivePanel: он же держит окно на экране, пока играет уход.
            if presentation.isVisible {
                PanelPill(
                    state: presentation.state,
                    // Язык идущей сессии, а не настройки: переключение на живой записи её не меняет.
                    language: controller.activeSessionLanguage ?? settings.language,
                    // Перевод сессии, а не настройки: правый ⌥ переводит вопреки выключенному
                    // тумблеру. Без переопределения (nil) всё как раньше — по тумблеру.
                    translateToEnglish: controller.activeSessionTranslate ?? settings.translateToEnglish,
                    // Живое число, а не кадр из `presentation`: очередь живёт своим темпом
                    // и меняется в том числе пока на экране доигрывает чужая вспышка.
                    pending: controller.pendingCount
                )
                .transition(accessibility.reduceMotion ? .opacity : .pill)
            }
        }
        // Окно больше пилюли: лишнее пространство прозрачно, пилюля висит по центру.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Кадр содержимого на ленте: горизонтальный сдвиг, расфокус и прозрачность.
/// Размытие — то, что превращает обычный слайд в «перещёлкивание» iOS-17.
private struct BlurPhase: ViewModifier {
    let radius: CGFloat
    let offsetX: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .offset(x: offsetX)
            .opacity(opacity)
    }
}

/// Кадр появления/ухода капсулы: масштаб, сдвиг по вертикали и прозрачность одним движением.
private struct PillPhase: ViewModifier {
    let scale: CGFloat
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(y: offset)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// Появление: капсула выплывает снизу, чуть мельче и прозрачная — пружина выносит её
    /// на место с лёгким перелётом. Уход мягче и короче: оседает вниз и гаснет, без пружины.
    fileprivate static let pill = AnyTransition.asymmetric(
        insertion: .modifier(
            active: PillPhase(scale: 0.88, offset: 10, opacity: 0),
            identity: PillPhase(scale: 1, offset: 0, opacity: 1)
        ),
        removal: .modifier(
            active: PillPhase(scale: 0.94, offset: 6, opacity: 0),
            identity: PillPhase(scale: 1, offset: 0, opacity: 1)
        )
    )
}

/// Пилюля без наблюдаемых объектов: то же дерево рисует и проба ImageRenderer,
/// которой неоткуда взять контроллер в нужном состоянии.
///
/// Слои стекла общие с карточками и живут в `GlassStyle`; здесь остаётся только форма
/// (капсула), содержимое и двойная тень. Радиус — строго половина высоты (22), его даёт
/// сама `Capsule()`; вложенные скругления концентрические: 22 минус отступ от края.
struct PanelPill: View {
    let state: DictationState
    let language: Language
    let translateToEnglish: Bool
    /// Сколько диктовок записано и ещё не доехало. Ноль по умолчанию: так пилюлю собирают
    /// и проба рендера, и всё, что про очередь ничего не знает.
    var pending: Int = 0

    @ObservedObject private var accessibility = HUDAccessibility.shared

    /// Габарит пилюли: один и тот же для записи и всех состояний обработки —
    /// панель не должна «дышать» размером на каждом шаге конвейера.
    static let width: CGFloat = 190
    static let height: CGFloat = 44
    /// Потолок ширины: сообщение об ошибке длиннее ярлыка, но панель всё равно остаётся маленькой.
    private static let maxWidth: CGFloat = 320

    /// Кант и блик проявляются на 50 мс позже тела: сначала прилетает стекло, потом на нём
    /// зажигается свет. Разница крошечная, но именно она читается как «дорого».
    @State private var chromeIn = false
    /// Вдох удачи: капсула чуть раздувается на «Вставлено» и тут же возвращается.
    @State private var breathing = false

    var body: some View {
        ZStack { content }
            // Средний вес, а не тонкий: на полупрозрачном фоне тонкий шрифт плывёт.
            .font(.system(size: 12, weight: .medium))
            // Длинная ошибка переносится, но выше двух строк пилюля не растёт.
            .lineLimit(2)
            // Стекло почти прозрачное, поэтому микротень под контентом обязательна:
            // над белым фоном она одна и держит буквы, а на тёмном её не видно.
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .padding(.horizontal, 14)
            .frame(minWidth: Self.width, maxWidth: Self.maxWidth, minHeight: Self.height)
            // Без `fixedSize` рамка забирает всю предложенную ширину окна и пилюля всегда
            // раздувается до потолка: измерено пробой (190/320 против 320/320).
            .fixedSize(horizontal: true, vertical: false)
            .background { GlassPlate(shape: Capsule()) }
            .overlay { GlassRim(shape: Capsule()).opacity(chromeIn ? 1 : 0) }
            .overlay { GlassSheen(shape: Capsule()).opacity(chromeIn ? 1 : 0) }
            // Блик поверх всего: он проходит и по стеклу, и по содержимому.
            .overlay { if !accessibility.reduceMotion { SpecularSweep(shape: Capsule()) } }
            // Без группировки тень рисовалась бы от каждого сабвью отдельно.
            .compositingGroup()
            // Две тени: широкая мягкая продаёт парение, плотная контактная даёт кромку.
            .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
            .shadow(color: .black.opacity(0.20), radius: 2.5, y: 1)
            .scaleEffect(breathing ? 1.015 : 1)
            // Схема фиксированно тёмная: только она читается над любым фоном — и над белым
            // документом, и над видео. Адаптивная полярность здесь только мигала бы.
            .environment(\.colorScheme, .dark)
            // Одна анимация на смену состояния: она же ведёт и подмену содержимого,
            // и морф ширины капсулы. Поток уровня внутри записи её не трогает.
            .animation(.snappy(duration: 0.28), value: stage)
            // Тем же движением капсула отращивает и убирает чип очереди: без этого она
            // прыгала бы по ширине рывком каждый раз, когда диктовка доезжает.
            .animation(.snappy(duration: 0.28), value: queued)
            .onAppear {
                guard !accessibility.reduceMotion else {
                    chromeIn = true
                    return
                }
                withAnimation(.easeOut(duration: 0.25).delay(0.05)) { chromeIn = true }
            }
            .onChange(of: stage) { _, new in
                // Успех отмечаем вдохом самой капсулы — один раз, полсекунды, еле заметно.
                guard new == .inserted, !accessibility.reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.25)) { breathing = true }
                withAnimation(.easeIn(duration: 0.25).delay(0.25)) { breathing = false }
            }
    }

    /// Ступень конвейера: различает состояния, но не уровень внутри `.recording` —
    /// иначе анимация ширины перезапускалась бы 12 раз в секунду.
    private enum Stage {
        case idle, preparing, recording, transcribing, cleaning, inserted, carded, cancelled,
             degraded, error
    }

    /// Сколько диктовок в работе ПОМИМО той, которую пилюля сейчас называет.
    ///
    /// Пилюля показывает одно дело, а с наложением их бывает два: одна пишется, другая
    /// доезжает. Второе дело — это чип с одной цифрой, а не вторая строка: панель обязана
    /// остаться маленькой (HIG Panels, «Keep HUDs small»).
    ///
    /// На записи пилюля называет живую диктовку, значит в счёт идёт вся очередь; на
    /// обработке она называет первую из очереди, значит в счёт идут остальные. Ноль — чипа
    /// нет вовсе: пустой слот на маленькой пилюле дороже отсутствующего числа.
    ///
    /// Не private: раскладку проверяет тест, а собрать пилюлю в нужном состоянии ему негде.
    static func queueBadge(state: DictationState, pending: Int) -> Int {
        switch state {
        case .recording: return max(0, pending)
        case .transcribing, .cleaning: return max(0, pending - 1)
        // На подготовке модели чипа нет намеренно: строка там и так длинная, а совпасть
        // с очередью она может только на первом запуске, когда очереди ещё неоткуда взяться.
        case .idle, .preparingModel, .inserted, .carded, .cancelled, .degraded, .error:
            return 0
        }
    }

    private var queued: Int { Self.queueBadge(state: state, pending: pending) }

    private var stage: Stage {
        switch state {
        case .idle: .idle
        case .preparingModel: .preparing
        case .recording: .recording
        case .transcribing: .transcribing
        case .cleaning: .cleaning
        case .inserted: .inserted
        case .carded: .carded
        case .cancelled: .cancelled
        case .degraded: .degraded
        case .error: .error
        }
    }

    /// Смена состояний — лента, едущая влево: отработавшее уходит за левый край, размываясь,
    /// новое подъезжает справа и наводится на резкость. Направление одно на всю цепочку —
    /// запись → распознаю → чищу → вставлено, поэтому конвейер читается как один механизм.
    /// Ветки `switch` — разные вью, поэтому переход срабатывает сам, без ручных `id`.
    ///
    /// Асимметрия по времени и есть хореография: уходящее успевает уйти (0.22) раньше, чем
    /// приезжает новое (задержка 0.1) — и раньше, чем растворяется само стекло на уходе панели.
    private var ticker: AnyTransition {
        guard !accessibility.reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition
                .modifier(
                    active: BlurPhase(radius: 4, offsetX: 18, opacity: 0),
                    identity: BlurPhase(radius: 0, offsetX: 0, opacity: 1)
                )
                .animation(.snappy(duration: 0.28).delay(0.1)),
            removal: AnyTransition
                .modifier(
                    active: BlurPhase(radius: 4, offsetX: -18, opacity: 0),
                    identity: BlurPhase(radius: 0, offsetX: 0, opacity: 1)
                )
                .animation(.easeOut(duration: 0.22))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()

        case .preparingModel(.downloading(let progress)):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("Качаю модель… \(Int(progress * 100))%")
            }
            .transition(ticker)

        case .preparingModel(.warming(let since)):
            // Полосы тут нет намеренно: прогресса компиляции под нейродвижок CoreML не
            // сообщает, а полная полоса, стоящая на месте, читается как «зависло» —
            // именно так это и выглядело на первом запуске. Секунды честнее.
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Готовлю модель · \(Self.elapsed(from: since, to: context.date))")
                }
            }
            .transition(ticker)

        case .recording(_, let level):
            // Живого текста в панели нет: только индикатор, язык, метка перевода и эквалайзер.
            HStack(spacing: 8) {
                RecordingDot(reduceMotion: accessibility.reduceMotion)
                Text(Self.flag(language))
                if translateToEnglish {
                    TranslationBadge()
                }
                EqualizerView(level: level, reduceMotion: accessibility.reduceMotion)
                // Вторая занятость: пока идёт эта запись, столько прошлых ещё доезжает.
                if queued > 0 {
                    QueueBadge(count: queued, reduceMotion: accessibility.reduceMotion)
                }
                // Единственная подсказка про отмену. Тише всего, что есть в пилюле, и
                // постоянной ширины — на потоке уровня (~12 раз в секунду) она не дёргается.
                // Белый с прозрачностью, не акцентный цвет: мелкий цветной текст на стекле грязнит.
                Text("esc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .transition(ticker)

        case .transcribing:
            spinnerRow("Распознаю…")

        case .cleaning:
            spinnerRow("✨ Чищу…")

        case .inserted:
            // Зелёная вспышка удачи: галочка обводится на глазах, свечение — на всей строке.
            HStack(spacing: 6) {
                DrawnCheck(reduceMotion: accessibility.reduceMotion)
                Text("Вставлено")
            }
            .foregroundStyle(Color.green)
            .shadow(color: .green.opacity(0.45), radius: 4)
            .transition(ticker)

        case .carded:
            // Не вставили — значит, некуда: текст ждёт карточкой внизу слева. Тон тот же,
            // что у удачи (это она и есть), но без зелени: вставки в приложение не было.
            FlashRow(symbol: "⤷", text: "В карточку", tint: .white, glowing: false,
                     reduceMotion: accessibility.reduceMotion)
                .transition(ticker)

        case .cancelled:
            FlashRow(symbol: "✕", text: "Отменено", tint: .white, glowing: false,
                     reduceMotion: accessibility.reduceMotion)
                .transition(ticker)

        case .degraded(let reason):
            Text("⚠️ \(Self.reasonText(reason))")
                .transition(ticker)

        case .error(let message):
            Text("⚠️ \(message)")
                .foregroundStyle(Color.red)
                .transition(ticker)
        }
    }

    private func spinnerRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.blue)
                // Спиннер только перетекает: крутящийся кружок, который ещё и едет, читается нервно.
                .transition(.opacity)
            Text(text)
                .transition(ticker)
            // Стадию пилюля называет у первой диктовки в очереди; чип говорит, сколько
            // таких же стоит за ней.
            if queued > 0 {
                QueueBadge(count: queued, reduceMotion: accessibility.reduceMotion)
                    .transition(ticker)
            }
        }
    }

    private static func flag(_ language: Language) -> String {
        switch language {
        case .ru: return "🇷🇺"
        case .uk: return "🇺🇦"
        case .en: return "🇬🇧"
        }
    }

    /// Время прогрева в виде «0:07». Минуты появляются сами, когда до них доходит:
    /// первая компиляция большой модели под нейродвижок и правда идёт минуты.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Контроллер маппит причины в русский текст сам, так что ветки ниже в норме недостижимы —
    /// они оставлены страховкой на случай, если в `.degraded` прилетит сырой технический код.
    private static func reasonText(_ reason: String) -> String {
        switch reason {
        case "secure input": return "Защищённое поле — нажмите ⌘V"
        case "no accessibility": return "Нет разрешения Accessibility"
        default: return reason
        }
    }
}

/// Индикатор записи: настоящий красный, а не семантический стиль — иерархические стили на стекле
/// обесцвечиваются. Белое свечение держит точку заметной и поверх тёмного видео,
/// а расходящееся кольцо-сонар превращает пульс в «идёт передача».
private struct RecordingDot: View {
    let reduceMotion: Bool

    @State private var pulsing = false
    @State private var sonar = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: .white.opacity(0.25), radius: 3)
            // Кольцо в оверлее: на компоновку не влияет, уходит за габарит точки.
            .overlay {
                Circle()
                    .stroke(Color.red, lineWidth: 1)
                    .scaleEffect(sonar ? 2.2 : 1)
                    .opacity(sonar ? 0 : 0.35)
                    // Волна расходится и начинается заново — период тот же, что у пульса.
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeOut(duration: 0.85).repeatForever(autoreverses: false),
                        value: sonar
                    )
            }
            // Пульс только по трансформации и прозрачности; покой — полный красный кружок,
            // поэтому при «Уменьшить движение» точка просто остаётся статичной.
            // Дно прозрачности высокое (0.8): на просвет точка не должна тускнеть до бурой.
            .scaleEffect(pulsing ? 1.18 : 1)
            .opacity(pulsing ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
            .onAppear {
                pulsing = !reduceMotion
                sonar = !reduceMotion
            }
    }
}

/// Галочка, которая сама себя рисует: путь обводится за 0.25 с и в конце чуть подпрыгивает.
/// Именно рисование (а не появление готового значка) читается как «сделано вот сейчас».
private struct DrawnCheck: View {
    let reduceMotion: Bool

    @State private var drawn: CGFloat = 0
    @State private var popped = false

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 5))
            path.addLine(to: CGPoint(x: 4, y: 9))
            path.addLine(to: CGPoint(x: 11, y: 0))
        }
        .trim(from: 0, to: drawn)
        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .frame(width: 11, height: 9)
        .scaleEffect(popped ? 1 : 0.86)
        .onAppear {
            guard !reduceMotion else {
                drawn = 1
                popped = true
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { drawn = 1 }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5).delay(0.22)) { popped = true }
        }
    }
}

/// Сжатие столбика к средней линии — отдельный модификатор, чтобы им можно было описать переход.
private struct BarScale: ViewModifier {
    let scale: CGFloat
    /// Сдвиг к середине ряда: столбики не просто оседают, а сходятся в точку.
    var pull: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: scale)
            .offset(x: pull)
    }
}

/// Итоговая вспышка: значок выпрыгивает пружиной, подпись въезжает вместе со строкой.
private struct FlashRow: View {
    let symbol: String
    let text: String
    let tint: Color
    let glowing: Bool
    let reduceMotion: Bool

    @State private var popped = false

    var body: some View {
        HStack(spacing: 6) {
            Text(symbol)
                .scaleEffect(popped ? 1 : 0.6)
            Text(text)
        }
        .foregroundStyle(tint)
        .shadow(color: tint.opacity(glowing ? 0.45 : 0), radius: 4)
        .onAppear {
            guard !reduceMotion else {
                popped = true
                return
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { popped = true }
        }
    }
}

/// Вторая занятость одним чипом: сколько диктовок доезжает помимо той, что названа строкой.
///
/// Три точки, бегущие волной, и цифра — это весь рассказ. Именованных стадий у второй
/// диктовки быть не может (строка в пилюле одна), а спиннера здесь нельзя: рядом уже
/// крутится либо эквалайзер, либо спиннер стадии, и второй вращающийся элемент читается
/// суетой. `variableColor.iterative` даёт то же «идёт работа» без единого пикселя движения
/// формы — и сам выключается при «Уменьшить движение».
private struct QueueBadge: View {
    let count: Int
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            Text("\(count)")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        // Плоская подложка, как у метки перевода: стекло на стекле выглядит дёшево.
        // Высота чипа 14 → его радиус 7 = 22 − 15 отступа от края капсулы, концентрично.
        .background(.white.opacity(0.10), in: Capsule())
        .fixedSize()
        .accessibilityLabel("ещё \(count) в обработке")
    }
}

/// Метка «перевод на английский включён»: результат придёт не на языке записи.
private struct TranslationBadge: View {
    var body: some View {
        Text("→ EN")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            // Плоская подложка, не второй материал: стекло на стекле выглядит дёшево.
            // Высота чипа 14 → его радиус 7 = 22 − 15 отступа от края капсулы, концентрично.
            .background(.white.opacity(0.10), in: Capsule())
            .fixedSize()
    }
}

/// Эквалайзер: столбики пляшут на месте, а не едут справа налево, как бегущая волна.
/// Высота столбика — текущий уровень, умноженный на его вес; веса пересчитываются
/// на каждом тике уровня, поэтому картинка переливается, оставаясь детерминированной.
/// Кадр держит у себя (`@State`): пересборка панели его не сбрасывает.
private struct EqualizerView: View {
    let level: Float
    let reduceMotion: Bool

    private static let barCount = 12
    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 4
    private static let maxBar: CGFloat = 22
    /// Столбик тишины — короткий штрих, а не пустое место.
    private static let minBar: CGFloat = 2.5

    /// Лента громкости: правый столбик — сейчас, левый — секунду назад. Каждый замер
    /// сдвигает ленту влево, и по ряду едет форма настоящей речи.
    ///
    /// Раньше высоты считались псевдослучайным весом на каждый замер. Движения было много,
    /// смысла — ноль: ряд одинаково дёргался и на слове, и на паузе, и глаз это распознавал
    /// как подделку. Теперь ни одного случайного числа: что видно, то и было сказано.
    private struct Frame: Equatable {
        var levels: [Float]

        init(level: Float) {
            levels = Array(repeating: level, count: EqualizerView.barCount)
        }

        mutating func push(_ level: Float) {
            levels.removeFirst()
            levels.append(level)
        }
    }

    @State private var frame: Frame
    /// Столбики встают волной, каждый следующий на 20 мс позже — эквалайзер «оживает»,
    /// а не возникает целиком.
    @State private var risen = false

    /// Стартовый кадр берём из первого же уровня, а не из нуля: иначе первая отрисовка
    /// (и статичная проба рендера) показывала бы штрихи тишины при живом звуке.
    init(level: Float, reduceMotion: Bool) {
        self.level = level
        self.reduceMotion = reduceMotion
        _frame = State(initialValue: Frame(level: level))
    }

    /// В тишине ряд не замирает плоской линией, а еле заметно дышит: молчащий эквалайзер
    /// выглядит зависшим, хотя приложение слушает. Порог низкий — дыхание не должно
    /// подмешиваться в настоящую речь.
    private var breathes: Bool {
        !reduceMotion && frame.levels.allSatisfy { MeterScale.height(of: $0) < 0.08 }
    }

    var body: some View {
        // Расписание кадров нужно только дыханию: под звук высоты ведёт анимация уровня,
        // и гонять таймер зря незачем.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !breathes)) { context in
            HStack(spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(Self.fill)
                        .frame(
                            width: Self.barWidth,
                            height: Self.barHeight(
                                bar: index,
                                frame: frame,
                                breath: Self.breath(bar: index, at: context.date, active: breathes)
                            )
                        )
                        .scaleEffect(x: 1, y: risen ? 1 : 0.04)
                        // Появление расходится от середины к краям, а не бежит слева направо:
                        // симметричное движение читается как расходящаяся волна. Разбег
                        // крайних столбиков — почти десятая секунды: при меньшем движение
                        // сливается в один кадр и волны не видно вовсе.
                        .animation(
                            reduceMotion
                                ? nil
                                : .spring(response: 0.5, dampingFraction: 0.75)
                                    .delay(Self.distanceFromCenter(index) * 0.09),
                            value: risen
                        )
                        // На уходе столбики схлопываются к средней линии — тоже волной и внутри
                        // общего сдвига влево: эквалайзер не обрывается кадром, а «садится».
                        .transition(Self.collapse(bar: index, reduceMotion: reduceMotion))
                }
            }
        }
        // Симметрия относительно средней линии: столбики центрируются по высоте полосы.
        .frame(height: Self.maxBar)
        // Свой ореол акцентного цвета: на почти прозрачном стекле поверх светлого контента
        // тонкие штрихи иначе выцветают.
        .shadow(color: Color.accentColor.opacity(0.45), radius: 2.5)
        // Одна короткая анимация на весь ряд, и никаких пружин с задержками по столбику.
        // Вес столбика — псевдослучайный и меняется на каждом замере: пружина начинает
        // догонять случайную цель, промахиваться и качаться обратно, у каждого столбика
        // в своей фазе, и ряд заметно дрожит. Инерция здесь не работает по построению.
        .animation(.easeOut(duration: 0.1), value: frame)
        .onChange(of: level) { _, new in
            frame.push(new)
        }
        // Волна разворачивается не в тот же миг, что и капсула: сначала на экран приезжает
        // стекло, и только потом внутри него раскрывается ряд. Без этой паузы нажатие ⌘
        // и появление волны сливаются в один кадр, и разглядеть движение невозможно.
        .onAppear {
            guard !reduceMotion else {
                risen = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { risen = true }
        }
    }

    /// Расстояние столбика от середины ряда, 0…1. Из него растут обе задержки — и появления,
    /// и отклика на звук, — поэтому движение всегда симметрично.
    private static func distanceFromCenter(_ bar: Int) -> Double {
        let center = Double(barCount - 1) / 2
        return abs(Double(bar) - center) / center
    }

    /// Дыхание тишины: медленная волна, бегущая по ряду. Ноль, когда дышать не надо, —
    /// тогда высота считается ровно как раньше.
    private static func breath(bar: Int, at date: Date, active: Bool) -> CGFloat {
        guard active else { return 0 }
        // Период около четырёх секунд, соседние столбики сдвинуты по фазе — ряд колышется,
        // а не пульсирует целиком.
        let phase = date.timeIntervalSinceReferenceDate * 0.5 + Double(bar) * 0.35
        return CGFloat((sin(phase) + 1) / 2)
    }

    /// Схлопывание столбика при уходе строки: вложенный переход отрабатывает вместе с общим,
    /// а задержка по номеру столбика и даёт волну.
    /// Уход эквалайзера: ряд сходится к середине и гаснет там точкой, из которой уже
    /// выезжает следующее состояние. Крайние столбики трогаются первыми, центральные —
    /// последними, поэтому движение читается как сбор, а не как обрыв.
    private static func collapse(bar: Int, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let distance = distanceFromCenter(bar)
        let center = Double(barCount - 1) / 2
        // Насколько столбику идти до середины: его позиция в ряду, взятая с обратным знаком.
        let pull = CGFloat(center - Double(bar)) * (barWidth + spacing)
        return AnyTransition
            .modifier(active: BarScale(scale: 0.04, pull: pull), identity: BarScale(scale: 1))
            .animation(.easeIn(duration: 0.22).delay((1 - distance) * 0.02))
    }

    private static func barHeight(bar: Int, frame: Frame, breath: CGFloat) -> CGFloat {
        // Дыхание добавляется поверх уровня, а не вместо него: на настоящей речи его не
        // видно (там свои десятки процентов), в тишине оно и есть всё движение.
        let loudness = MeterScale.height(of: frame.levels[bar]) + breath * breathDepth
        return minBar + min(1, loudness) * (maxBar - minBar)
    }

    /// Насколько высоко поднимается дыхание тишины. Больше — и молчащий эквалайзер начнёт
    /// притворяться, что слышит речь.
    private static let breathDepth: CGFloat = 0.09


    /// Акцентный градиент остаётся настоящим цветом поверх стекла — вибрантным его делать нельзя,
    /// иначе полоски выцветут в серые штрихи.
    private static let fill = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
        startPoint: .top,
        endPoint: .bottom
    )
}
