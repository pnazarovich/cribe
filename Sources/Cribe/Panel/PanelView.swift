import AppKit
import OSLog
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
                    translationTarget: settings.translationTarget,
                    // Живое число, а не кадр из `presentation`: очередь живёт своим темпом
                    // и меняется в том числе пока на экране доигрывает чужая вспышка.
                    pending: controller.pendingCount,
                    style: settings.pillStyle
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
    var translationTarget: TranslationTarget = .en
    /// Сколько диктовок записано и ещё не доехало. Ноль по умолчанию: так пилюлю собирают
    /// и проба рендера, и всё, что про очередь ничего не знает.
    var pending: Int = 0
    /// Волна или бегущая строка на записи.
    var style: PillStyle = .wave

    @ObservedObject private var accessibility = HUDAccessibility.shared

    /// Габарит пилюли: один и тот же для записи и всех состояний обработки —
    /// панель не должна «дышать» размером на каждом шаге конвейера.
    static let width: CGFloat = 190
    static let height: CGFloat = 44
    /// Потолок ширины: сообщение об ошибке длиннее ярлыка, но панель всё равно остаётся маленькой.
    private static let maxWidth: CGFloat = 320
    /// Ширина капсулы, пока в ней едет бегущая строка. 300 pt не «на глаз»: ровно столько же
    /// в ширину карточка, в которую эта же диктовка улетает, — крупнее предмета, который
    /// приложение и так кладёт на чужой экран, капсула становиться не должна. В окно панели
    /// (380 pt) входит с запасом на тень.
    static let wordsWidth: CGFloat = 300

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
            // Со строкой ширина ЗАДАНА, а не выведена из содержимого: остаток внутри достаётся
            // строке, поэтому чип очереди отъедает у неё, а не раздувает капсулу. Иначе капсула
            // с флагом, «→ EN» и чипом просила бы 328 pt при потолке 320 — и потолок
            // отыгрывался бы на подписях, потому что строка фиксированной ширины сжиматься
            // не умеет.
            .frame(
                minWidth: showsTicker ? Self.wordsWidth : Self.width,
                maxWidth: showsTicker ? Self.wordsWidth : Self.maxWidth,
                minHeight: Self.height
            )
            // Без `fixedSize` рамка забирает всю предложенную ширину окна и пилюля всегда
            // раздувается до потолка: измерено пробой (190/320 против 320/320). Со строкой
            // подпирать нечем — там min и max совпали, ширина уже определена.
            .fixedSize(horizontal: !showsTicker, vertical: false)
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
            // Тем же движением капсула открывает слот под бегущую строку. Без этого рост
            // 190 → 300 случался бы кадром: `live` не входит ни в одну анимацию, а `stage`
            // на появлении первых слов не меняется. Движение одно за диктовку — строка
            // приходит на четвёртом распознанном слове, а сужается капсула уже на «Распознаю…».
            .animation(.snappy(duration: 0.28), value: showsTicker)
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

    /// Едет ли в капсуле прямо сейчас бегущая строка. Одно место на два применения — и на
    /// выбор содержимого, и на ширину: разъедься они, слот и капсула перестанут совпадать.
    private var showsTicker: Bool {
        guard style == .words, case .recording(let live, _) = state else { return false }
        return !live.isEmpty
    }

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
                    Text(Self.preparingText(since: since, now: context.date))
                }
            }
            .transition(ticker)

        case .recording(let live, let level):
            // Живого текста в панели нет: только индикатор, язык, метка перевода и эквалайзер.
            HStack(spacing: 8) {
                RecordingDot(reduceMotion: accessibility.reduceMotion)
                Text(Self.flag(language))
                if translateToEnglish {
                    TranslationBadge(target: translationTarget)
                }
                // Бегущая строка встаёт на место волны, а не рядом: место в капсуле одно.
                // Пока распознавание не отдало первых слов, показываем волну — пустое место
                // на старте записи читалось бы как «не слышит».
                if showsTicker {
                    LiveTicker(text: live, reduceMotion: accessibility.reduceMotion)
                        .transition(.opacity)
                } else {
                    EqualizerView(level: level, reduceMotion: accessibility.reduceMotion)
                        .transition(.opacity)
                }
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
            // Тот же слой делает две разные работы, и называть их одним словом — врать.
            // На переводящей диктовке (правый ⌥) он не чистит русский, а отдаёт английский;
            // человек в этот момент ждёт именно перевода и должен видеть, что его и делают.
            spinnerRow(translateToEnglish ? "🌐 Перевожу…" : "✨ Чищу…")

        case .inserted:
            // Сюда панель не приходит: удачная вставка гасит капсулу, не меняя её содержимого
            // (см. `LivePanel.handle`). Текст уже стоит в поле — сообщать об этом поверх него
            // нечего, и капсула просто уходит.
            EmptyView()

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
    /// Что написать, пока модель поднимается.
    ///
    /// Обычно это две секунды, и хватает секундомера. Но первая загрузка ПОСЛЕ ОБНОВЛЕНИЯ
    /// приложения занимает минуты: CoreML заново компилирует модель под Neural Engine, и
    /// всё это время процесс стоит внутри системного загрузчика с нулевым процессором.
    /// Замерено на живом запуске: 121,9 с против 2,4 с на прогретом кэше. Без объяснения
    /// это выглядит как зависание — и именно так о нём и сообщали.
    static func preparingText(since: Date, now: Date) -> String {
        let base = "Готовлю модель · \(elapsed(from: since, to: now))"
        guard now.timeIntervalSince(since) >= longPreparation else { return base }
        return base + " · разовая подготовка после обновления"
    }

    /// С какой секунды пора объяснять. Обычная загрузка укладывается в несколько секунд,
    /// так что раньше объяснять нечего — и не нужно пугать словом «компиляция» там,
    /// где всё и так вот-вот закончится.
    static let longPreparation: TimeInterval = 15

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
    let target: TranslationTarget

    var body: some View {
        // Код языка, а не название: в капсуле места на две буквы, и «→ PL» читается
        // с одного взгляда, а «→ Польский» туда попросту не влезет.
        Text("→ \(target.rawValue.uppercased())")
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

/// Бегущая строка распознанного: свежие слова приходят справа, старые уезжают влево
/// и растворяются в дымке.
///
/// **Что здесь движется.** Не ширина текста, а сама лента: сдвиг слоя (`offset`) не трогает
/// вёрстку, поэтому строка не переукладывается и не «резинит». Ширину анимировать нечем —
/// склейка режет строку слева (`LiveTranscript.keptWords`), и на длинной диктовке текст
/// перестаёт удлиняться вовсе, хотя речь идёт. Честная мера пути одна: ширина того, что
/// дописано ПОСЛЕ якоря.
///
/// **Почему по времени, а не пружиной.** Тот же вывод, что и у волны рядом
/// (см. `EqualizerView`): затухание в конце каждого шага читается отдельным рывком двенадцать
/// раз в минуту, а не инерцией. Положение — функция от времени, а не сумма по кадрам:
/// пропущенный кадр иначе съедал бы кусок пути и лента не доезжала бы до места.
///
/// **Дымка** сделана двумя копиями одного текста: резкая видна везде, кроме полос по краям,
/// размытая — только в них. Маски накладываются на ОКНО, а не на `Text`. Это не косметика:
/// `mask` получает размер маскируемого вью, и пока маски висели на ленте, градиенты
/// растягивались на всю её длину — в окно попадал только их правый хвост, где резкая копия
/// уже прозрачна. На речи длиннее пары секунд от строки оставалась одна размытая копия;
/// отсюда и было «текста вообще не видно».
struct LiveTicker: View {
    let text: String
    let reduceMotion: Bool

    /// Своей ширины у окна нет намеренно: её задаёт капсула (`PanelPill.wordsWidth`),
    /// а внутри капсулы окну достаётся то, что осталось от флага, чипов и «esc». Так чип
    /// очереди отъедает у строки, а не раздувает капсулу.
    private static let minWidth: CGFloat = 110
    private static let height: CGFloat = 18
    static let fontSize: CGFloat = 12
    /// Радиус размытия. 2,6 было не видно вовсе на двенадцатом кегле: дымка читалась как
    /// «текст просто гаснет к краю», а не как расфокус.
    private static let blur: CGFloat = 4

    /// Левая полоса растворения — в ТОЧКАХ, а не в долях ширины: иначе расширение окна
    /// уходило бы в дымку в той же пропорции, в какой прибавилось резкого текста. Ровно
    /// на одно уезжающее слово с запасом — на меньшем расстоянии расфокус не успевает
    /// прочитаться и выглядит грязью.
    private static let haze: CGFloat = 56
    /// Правая — та, из которой слово въезжает. Была шесть точек: слово возникало почти
    /// срезом. Двадцать четыре — слово проявляется целиком, и это ровно та граница, за
    /// которой начало бы страдать главное: справа стоит «сейчас», ради которого строка
    /// и заведена, и держать его в постоянной мути нельзя.
    private static let entry: CGFloat = 24

    /// Насколько плавно меняется сама скорость. Без сглаживания лента разгонялась
    /// и тормозила мгновенно на каждом приходе текста — и это читалось как дёрганье,
    /// хотя ход формально был непрерывным.
    private static let easing: TimeInterval = 0.6
    /// За сколько лента исправляет расхождение между тем, где она есть, и тем, где ей
    /// полагается быть. Мягко и медленно: это поправка к ходу, а не сам ход.
    ///
    /// Обязана быть МЕДЛЕННЕЕ прихода текста. Когда она была вдвое короче промежутка между
    /// проходами, лента успевала выесть расхождение до нуля, приходил следующий кусок,
    /// и она разгонялась снова — качание 215→407→215 pt/с каждый проход, то самое дёрганье.
    private static let correction: TimeInterval = 2.2

    /// Насколько быстро забывается темп речи ПОСЛЕ того, как речь кончилась.
    private static let rateMemory: TimeInterval = 1.2

    /// Через сколько молчания считаем, что речь прервалась, и начинаем забывать темп.
    ///
    /// Длиннее промежутка между проходами — иначе темп затухал бы между обычными кусками
    /// и восстанавливался скачком. Так и было: затухание работало каждый кадр, оценка
    /// выходила на треть ниже настоящей, и лента систематически не поспевала за речью.
    private static let silenceAfter: TimeInterval = 1.9

    /// Какую долю пришедшего куска лента держит в запасе — на неё она и отстаёт, пока
    /// человек говорит. Без запаса лента упирается в конец текста и замирает до следующего
    /// прохода, а это дёрганый ход раз в секунду.
    ///
    /// Доля КУСКА, а не доля секунды. Текст приходит пилой: раз в проход прибавляется целый
    /// кусок и плавно тает. Запас, отмеренный в секундах, был меньше зубца этой пилы —
    /// низшая точка садилась на ноль, и лента раз за проход упиралась в конец текста.
    /// Половина куска держит низшую точку над нулём при любом темпе речи сама собой,
    /// без отдельного слежения за минимумом.
    private static let bufferShare: CGFloat = 0.5

    /// Медленнее этого лента считается стоящей — тогда и кадры считать незачем.
    ///
    /// Порог тут ТОЛЬКО на это. Гасить им сам ход нельзя, а раньше он гасил: скорость
    /// обнулялась каждым кадром, не прошедшим порог, — при том что за кадр фильтр поднимает
    /// её лишь до `desired · step / easing`. Выходило, что лента не трогалась с места вовсе,
    /// пока речь медленнее полутора слов в секунду, и порог этот зависел от частоты кадров:
    /// вдвое чаще кадры — вдвое выше порог. Регулятору нельзя опираться на расписание
    /// отрисовки.
    private static let stillness: CGFloat = 1.5

    /// Предохранитель на ход. В обычной речи не срабатывает никогда: склейка не даёт одному
    /// проходу дописать больше `LiveTranscript.maxTail` слов, и расхождение не вырастает
    /// настолько, чтобы упереться. Стоит на случай, если что-то в конвейере вывалит в строку
    /// разом больше, чем человек успел сказать.
    private static let maxSpeed: CGFloat = 600

    /// Быстрее человек не говорит. Потолок нужен не речи, а разовому большому куску:
    /// когда склейка не сошлась три прохода подряд, она вываливает в строку целый проход,
    /// и померенный по нему темп выходит вчетверо выше настоящего. Лента после такого
    /// выедала расхождение до нуля и стояла, пока завышенная оценка не осядет. Семь слов
    /// в секунду не говорит никто: живая речь в потолок не упирается, а выброс он срезает.
    private static let maxRate: CGFloat = 400

    /// Слово ленты вместе со своим НОМЕРОМ В СТРОКЕ.
    ///
    /// Номер здесь — не бухгалтерия, а лекарство от мигания. Опознавать слова по месту
    /// в окне можно было ровно до того, как строка перерастёт окно: дальше окно каждый
    /// проход съезжает влево, в каждой ячейке оказывается ДРУГОЕ слово, и SwiftUI
    /// добросовестно растворяет содержимое всех ячеек разом — вся строка моргает каждый
    /// проход, то есть раз в секунду. С номером в строке дописанное слово не трогает
    /// ни одного соседа, и растворяется ровно то, что и правда переписала склейка.
    struct Word: Equatable, Identifiable {
        let id: Int
        let text: String
    }

    /// Лента: что написано, где она стоит и с какой скоростью едет.
    ///
    /// Положение считается ОТ НАЧАЛА СТРОКИ, а не «на сколько отстали от конца». Разница
    /// не в записи, а в том, что от записи ломалось. При счёте от конца дописанное слово
    /// обязано было двинуть строку на свою ширину И ровно на столько же поправить
    /// отставание — два движения, гасящих друг друга. Гасили они друг друга только
    /// на бумаге: ширину строки SwiftUI менял анимированно, за треть секунды, а отставание
    /// менялось кадром. На каждом приходе уже прочитанные слова прыгали вправо на ширину
    /// нового слова и треть секунды ползли обратно. Считая от начала, дописанное не двигает
    /// строку вовсе: `shown` не меняется, растёт только длина. Гасить нечего, потому что
    /// нечему и возникать.
    ///
    /// Ход при этом непрерывный: скорость ведёт замеренный темп речи, а поправка лишь
    /// удерживает ленту на нужном расстоянии от конца текста.
    struct Tape: Equatable {
        /// Вся строка, как её отдала склейка.
        private(set) var words: [String] = []
        /// Сколько точек строки уже ушло за левый край окна. Растёт — лента едет.
        private(set) var shown: CGFloat = 0
        /// Текущая скорость, точек в секунду.
        private(set) var speed: CGFloat = 0
        /// Замеренный темп речи, точек текста в секунду. Это и есть та величина, за которой
        /// лента следует: ход задаёт речь, а не таймер.
        private(set) var rate: CGFloat = 0
        /// Замеренный промежуток между приходами. Именно замеренный: он складывается
        /// из паузы цикла И длительности самого прохода распознавания, а та зависит
        /// от машины, от длины окна и от того, чем ещё занят процессор.
        private(set) var period: TimeInterval = 0.8
        /// Ширина окна. Без неё не сказать, где «догнала»; приходит от геометрии.
        private(set) var window: CGFloat = LiveTicker.minWidth
        /// Счётчик правок: растёт, когда склейка переписала УЖЕ показанное слово.
        ///
        /// Анимация ширины привязана к нему, а не к составу слов, и вот почему. Состав
        /// меняется ещё и когда слово уезжает за левый край: строка теряет его ширину,
        /// а сдвиг ровно на неё же и подскакивает — два движения, гасящих друг друга
        /// в ОДНОМ кадре. Анимируй их — и гаснуть они перестанут: ширина поедет треть
        /// секунды, а сдвиг прыгнет сразу.
        private(set) var revision = 0
        /// `edge[i]` — где кончается i-е слово, считая от начала строки в точках. Слово
        /// занимает `edge[i-1] ..< edge[i]` вместе с пробелом перед собой.
        private var edge: [CGFloat] = []
        private var frame = Date.distantPast
        private var arrived = Date.distantPast

        /// Длина всей строки в точках.
        var total: CGFloat { edge.last ?? 0 }

        /// Куда лента доедет, если её не торопить: последнее слово у правого края окна.
        ///
        /// Может быть и ОТРИЦАТЕЛЬНЫМ — пока строка короче окна. Ноль тут был не защитой,
        /// а бедой: при выравнивании по левому краю строка вставала в x = 0, то есть прямо
        /// в полосу растворения, и первые полсотни точек свежей строки показывались
        /// полупрозрачными и размытыми. А ведь слева от них ничего не уезжало. С
        /// отрицательным концом короткая строка стоит у ПРАВОГО края, как ей и положено,
        /// и въезжает в окно тем же ходом, без единого особого случая.
        private var finish: CGFloat { total - window }

        /// Насколько правый конец строки ушёл за правый край окна — то, что лента ещё
        /// не показала.
        var lag: CGFloat { max(0, finish - shown) }

        /// Стоит ли лента совсем — тогда и кадры считать незачем.
        var isSettled: Bool { lag <= 0.5 && speed < LiveTicker.stillness }

        /// Сколько лента держит в запасе при нынешнем темпе речи.
        var buffer: CGFloat { rate * CGFloat(period) * LiveTicker.bufferShare }

        /// Вся строка целиком — для проверок и для «Уменьшить движение».
        var text: String { words.joined(separator: " ") }

        /// Что показывать и где: слова, попадающие в окно, и сдвиг первого из них
        /// относительно левого края окна. Сдвиг обычно отрицательный — слово начинается
        /// левее окна и уезжает под дымку.
        ///
        /// Слова выбираются ПО МЕСТУ в строке, а не «последние десять». Фиксированным
        /// числом слов хвост считать нельзя: окно слов съезжает влево не тогда же, когда
        /// едет лента, и разницу пришлось бы подкручивать поправкой на каждом приходе —
        /// то есть заводить ровно тот механизм, из-за которого всё и прыгало.
        var viewport: (words: [Word], offset: CGFloat) {
            guard !edge.isEmpty else { return ([], 0) }
            var first = firstVisible
            guard first < edge.count else { return ([], 0) }
            // Одно слово запаса слева. Состав окна меняется не только от правок, но и
            // просто от хода — слово уезжает за край и выбывает. Выбывает оно в том же
            // кадре, в котором сдвиг подскакивает на его ширину, и эти двое гасят друг
            // друга ровно до тех пор, пока их не расцепит анимация. Запас уводит место
            // выбывания за левый край нарисованного, под самую дымку, где увидеть его
            // уже нечем.
            first = max(0, first - 1)
            let right = shown + window
            var last = first
            while last + 1 < edge.count, start(last + 1) < right { last += 1 }
            return ((first...last).map { Word(id: $0, text: words[$0]) }, start(first) - shown)
        }

        /// Первое слово, которое ещё не уехало за левый край окна целиком.
        private var firstVisible: Int {
            var index = 0
            while index < edge.count, edge[index] <= shown { index += 1 }
            return index
        }

        /// Где начинается слово: сразу за концом предыдущего.
        private func start(_ index: Int) -> CGFloat { index == 0 ? 0 : edge[index - 1] }

        /// Окно поменяло ширину. Расхождение сохраняем — иначе лента прыгнула бы на разницу.
        mutating func resize(to width: CGFloat) {
            guard width > 0, width != window else { return }
            let keep = lag
            window = width
            shown = finish - keep
        }

        /// Доехать немедленно: так лента ведёт себя при «Уменьшить движение».
        mutating func settle() {
            shown = finish
            speed = 0
        }

        /// Принимает новую строку: перемеряет её и уточняет по ней темп речи.
        mutating func aim(at fresh: [String], now: Date = Date()) {
            let wasEmpty = words.isEmpty
            let before = total
            measure(fresh)
            defer { arrived = now }

            // Первая строка приезжает на место целиком: пустая капсула там, где человек
            // уже говорит, хуже любого движения.
            guard !wasEmpty else {
                shown = finish
                return
            }
            // Дописанное строку НЕ двигает — в этом весь смысл счёта от начала. Двигается
            // только правый конец, и расхождение растёт на ширину дописанного само собой,
            // без единой поправки.
            let added = total - before
            guard added > 0 else { return }

            guard arrived != .distantPast else { return }
            let elapsed = now.timeIntervalSince(arrived)
            guard elapsed > 0.05 else { return }
            period += (min(3, elapsed) - period) * 0.3
            let measured = min(LiveTicker.maxRate, added / CGFloat(elapsed))
            // Сглаживаем по приходам, а не по времени: речь неровная, и одно длинное слово
            // не должно разгонять ленту рывком, — но и занижать оценку затуханием нельзя,
            // иначе лента никогда не поспеет за речью.
            rate += (measured - rate) * 0.4
        }

        /// Перемеряет строку с первого изменившегося слова: на каждом приходе меняется
        /// хвост, а начало стоит с самого начала диктовки, и мерить его заново незачем.
        ///
        /// И держит показанное на месте, когда правка пришлась на ЗАКАДРОВОЕ слово. Это
        /// не редкий случай, а самый частый: склейка на каждом сошедшемся проходе переписывает
        /// всё перекрытие — под два десятка слов, — а в окне их видно четыре-пять. Стоит
        /// доехать запятой или заглавной к слову, уехавшему влево полминуты назад, как все
        /// границы за ней сдвигаются на её ширину, а `shown` — абсолютная координата —
        /// остаётся прежним. Видимый текст от этого телепортируется на ту же разницу,
        /// хотя лента никуда не ехала. На настоящей записи так дёргалось две трети приходов.
        ///
        /// Держим не координату, а СЛОВО: сколько сдвинулось начало первого видимого слова,
        /// на столько же сдвигаем и ленту. Тогда на экране не двигается ничего, а правка,
        /// пришедшаяся на видимое слово, спокойно доезжает анимацией.
        private mutating func measure(_ fresh: [String]) {
            let anchor = firstVisible
            let was = edge.isEmpty ? 0 : start(anchor)

            var from = 0
            while from < words.count, from < fresh.count, words[from] == fresh[from] { from += 1 }
            // Изменилось слово, которое уже стояло в строке, — это правка, а не дописка.
            if from < words.count { revision += 1 }
            words = fresh
            edge = Array(edge.prefix(from))
            for index in from..<fresh.count {
                let chunk = index == 0 ? fresh[index] : " " + fresh[index]
                edge.append((edge.last ?? 0) + LiveTicker.textWidth(chunk))
            }

            if anchor < edge.count { shown += start(anchor) - was }
            // Правка бывает и короче прежнего написания — тогда конец текста уезжает влево
            // и может оказаться позади ленты. Ехать назад ей нельзя, но и стоять за концом
            // строки тоже: `viewport` там не находит ни одного слова и отдаёт пустоту,
            // а `isSettled` при этом рапортует «доехала». Капсула гасла посреди речи.
            shown = min(shown, finish)
        }

        /// Кадр: ведёт ленту за темпом речи и мягко подправляет расхождение.
        mutating func advance(to now: Date) {
            defer { frame = now }
            let step = now.timeIntervalSince(frame)
            // Первый кадр и кадр после долгого простоя не двигают ленту: `step` там не время
            // между кадрами, а время с прошлой записи.
            guard step > 0, step < 0.5 else { return }

            // Темп забывается ТОЛЬКО после молчания. Затухание на каждом кадре занижало
            // оценку на треть: лента шла медленнее речи всегда и потому копила расхождение.
            if now.timeIntervalSince(arrived) > LiveTicker.silenceAfter {
                rate *= CGFloat(exp(-step / LiveTicker.rateMemory))
            }

            // Ход = темп речи плюс поправка на расхождение с запасом. Поправку ведёт САМО
            // расхождение — и это не мелочь. На его месте стояло поле, которому никто
            // ничего не присваивал: обратная связь была объявлена и не подключена, ход
            // выходил равным `rate − buffer / correction` при любом расхождении, то есть
            // на постоянную долю МЕДЛЕННЕЕ речи. Лента отставала всё сильнее, упиралась
            // в потолок отставания и с каждым приходом перешагивала к нему рывком.
            let desired = min(
                LiveTicker.maxSpeed,
                max(0, rate + (lag - buffer) / CGFloat(LiveTicker.correction))
            )
            speed += (desired - speed) * CGFloat(min(1, step / LiveTicker.easing))

            // Дальше конца текста ехать некуда, а скорость, которую некуда потратить,
            // копить нельзя: иначе лента трогается с места сразу на полном ходу.
            let wanted = speed * CGFloat(step)
            let travel = min(wanted, finish - shown)
            guard travel > 0 else {
                speed = 0
                return
            }
            shown += travel
            if travel < wanted { speed = travel / CGFloat(step) }
        }
    }


    @State private var tape = Tape()

    var body: some View {
        // Слот остаётся пустым `Color.clear`, а лента живёт в его накладке: `fixedSize`
        // пробрасывает наверх свою полную ширину как минимальную, и в общей раскладке
        // лента распирала бы капсулу.
        Color.clear
            .frame(minWidth: Self.minWidth, maxWidth: .infinity)
            .frame(height: Self.height)
            .overlay {
                // Ширину окна берём `GeometryReader`-ом и задаём ленте ЯВНО. Это и была
                // та самая «обрезка не там»: `frame(maxWidth: .infinity)` над текстом
                // с `fixedSize` не сжимает его до предложенной ширины — рамка вырастает
                // до длины текста. Дальше всё сходится одно к одному: маски считаются
                // по этой рамке, значит полосы растворения оказываются на сотню точек
                // ЗА краями окна (замерено `PillWidthTests`: у левого края текст выходил
                // ярче, чем в середине, — то есть дымки там не было вовсе).
                GeometryReader { geometry in
                    Group {
                        // При «Уменьшить движение» лента не едет вовсе: строка встаёт
                        // на место целиком очередным проходом распознавания.
                        if reduceMotion {
                            line(width: geometry.size.width)
                        } else {
                            // Расписание кадров останавливается, как только лента доехала:
                            // полотно панели и так пересобирается двенадцать раз в секунду.
                            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: tape.isSettled)) { context in
                                line(width: geometry.size.width)
                                    .onChange(of: context.date) { _, now in tape.advance(to: now) }
                            }
                        }
                    }
                    .onChange(of: geometry.size.width, initial: true) { _, width in
                        tape.resize(to: width)
                    }
                }
            }
            .onChange(of: text, initial: true) { _, fresh in
                tape.aim(at: fresh.split(separator: " ").map(String.init), now: Date())
                if reduceMotion { tape.settle() }
            }
    }

    /// Две копии текста под взаимно обратными масками, обе — точно по ширине окна.
    ///
    /// Обрезки здесь нет: маски и есть обрезка. За их краями альфа нулевая, и всё, что
    /// вылезло, гаснет само. Отдельный `clipped()` тут был бы лишним и вредным — он режет
    /// ДО размытия, и `blur` размазывал бы не текст, а срез по рамке: вместо дымки
    /// на краю получался бы бледный призрак.
    private func line(width: CGFloat) -> some View {
        let viewport = tape.viewport
        let words = viewport.words
        let text = HStack(spacing: 0) {
            // Каждое слово — своё вью, и это не украшение. Склейка переписывает уже
            // показанные слова, когда следующий проход слышит их лучше: обрывок становится
            // целым словом, доезжает запятая, чинится ослышка. Одним `Text` такая правка
            // была бы подменой всей строки разом — то есть миганием; здесь же растворяется
            // ровно то слово, которое изменилось, а соседние стоят на месте.
            //
            // Опознаётся слово по номеру в СТРОКЕ, а не по месту в окне и не по написанию.
            // По месту в окне опознавать можно было ровно до того, как строка перерастёт
            // окно: дальше окно каждый проход съезжает влево, в каждой ячейке оказывается
            // ДРУГОЕ слово, и SwiftUI добросовестно растворяет их все разом — вся строка
            // моргает каждый проход.
            ForEach(words) { word in
                // Пробел приклеивается к слову СЛЕВА и по номеру в строке, а не по месту
                // в окне: ширины слов посчитаны так же, и только при этом сдвиг ленты
                // сходится с нарисованным до точки.
                Text(word.id == 0 ? word.text : " " + word.text)
                    .contentTransition(.opacity)
            }
        }
        .font(.system(size: Self.fontSize, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
        // Лента меряется собой, а не рамкой: только так она выходит за края окна и уезжает
        // под дымку, вместо того чтобы сжиматься.
        .fixedSize(horizontal: true, vertical: false)
        // Анимация — на ПРАВКИ, а не на состав слов.
        //
        // `contentTransition` растворяет только пиксели, ширину он не анимирует, а правка
        // почти всегда меняет ширину: «эсэсэйч» короче, чем SSH, «прокид» длиннее, чем
        // Parakeet. Правку анимировать надо. А вот выезд слова за левый край — ни в коем
        // случае: там строка теряет ширину слова, и ровно на неё же подскакивает сдвиг.
        // Эти двое гасят друг друга в одном кадре, и анимировать одного из них значит
        // расцепить их — ширина поедет треть секунды, сдвиг прыгнет сразу.
        .animation(.easeInOut(duration: 0.32), value: tape.revision)
        .offset(x: viewport.offset)
        // Ширина ЗАДАНА числом, а выравнивание — по левому краю: положение ленты целиком
        // в `offset`, и рамке двигать её нечем.
        .frame(width: width, alignment: .leading)
        .frame(height: Self.height)

        let dissolve = Self.dissolve(after: tape.shown)
        return ZStack {
            text.mask(Self.sharpMask(dissolve: dissolve))
            text.blur(radius: Self.blur).mask(Self.hazyMask(dissolve: dissolve))
        }
        .frame(width: width, height: Self.height)
    }

    /// Резкая копия видна везде, кроме полос растворения по краям.
    private static func sharpMask(dissolve: CGFloat) -> some View {
        HStack(spacing: 0) {
            band(from: .clear, to: .black).frame(width: dissolve)
            Color.black
            band(from: .black, to: .clear).frame(width: entry)
        }
    }

    /// Насколько широка левая дымка ПРЯМО СЕЙЧАС.
    ///
    /// Дымка слева означает ровно одно: «текст продолжается за краем». Пока за край ничего
    /// не уехало, растворять нечего, и полная полоса просто съедала бы начало свежей строки.
    /// Растёт вместе с уехавшим и упирается в свою полную ширину — то есть ровно тогда,
    /// когда за краем и правда есть что растворять.
    private static func dissolve(after shown: CGFloat) -> CGFloat {
        min(haze, max(0, shown))
    }

    /// Размытая — ровно наоборот: только в полосах, где резкая уже погасла. Сумма двух масок
    /// вдоль полосы держится около единицы, поэтому текст не проваливается в яму прозрачности
    /// на стыке.
    private static func hazyMask(dissolve: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: dissolve)
            Color.clear
            band(from: .clear, to: .black).frame(width: entry)
        }
    }

    private static func band(from: Color, to: Color) -> LinearGradient {
        LinearGradient(colors: [from, to], startPoint: .leading, endPoint: .trailing)
    }

    /// Ширина строки на ленте. Меряем шрифтом AppKit, а не `GeometryReader`: геометрия
    /// приезжает следующим проходом вёрстки, то есть на кадр позже прихода текста, — а сдвиг
    /// нужен в тот же кадр. Расхождение с раскладкой `Text` — доли процента и ни на что
    /// не влияет: арифметика задаёт только ПУТЬ, конечное место держит вёрстка.
    static func textWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: ruler]).width
    }

    /// Вычисляемый, а не хранимый: `NSFont` не `Sendable`, а системные шрифты AppKit
    /// и так кэширует.
    private static var ruler: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
}

/// Эквалайзер: столбики пляшут на месте, а не едут справа налево, как бегущая волна.
/// Высота столбика — текущий уровень, умноженный на его вес; веса пересчитываются
/// на каждом тике уровня, поэтому картинка переливается, оставаясь детерминированной.
/// Кадр держит у себя (`@State`): пересборка панели его не сбрасывает.
struct EqualizerView: View {
    let level: Float
    let reduceMotion: Bool

    private static let barCount = 12
    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 4
    private static let maxBar: CGFloat = 22
    /// Столбик тишины — тонкий штрих, почти ноль: ряд молчит, но остаётся рядом.
    private static let minBar: CGFloat = 1.5

    /// Лента громкости: каждый замер сдвигает её, и по ряду едет форма настоящей речи.
    /// Хранит **готовые высоты**, а не уровни: границы шкалы плавают под шум комнаты, и
    /// пересчёт всей ленты на каждый сдвиг перерисовывал бы разом и старые столбики.
    ///
    /// Раньше высоты считались псевдослучайным весом на каждый замер. Движения было много,
    /// смысла — ноль: ряд одинаково дёргался и на слове, и на паузе, и глаз это распознавал
    /// как подделку. Теперь ни одного случайного числа: что видно, то и было сказано.
    private struct Frame: Equatable {
        var heights: [CGFloat]

        init() {
            heights = Array(repeating: 0, count: EqualizerView.barCount)
        }

        mutating func push(_ height: CGFloat) {
            // Новый замер встаёт слева, лента уезжает вправо. Осциллографы и «Диктофон»
            // делают наоборот («сейчас» справа, история слева), но здесь выбор владельца.
            heights.removeLast()
            heights.insert(height, at: 0)
        }
    }

    @State private var frame: Frame
    /// Границы шкалы живут рядом с лентой: они считаются по тем же уровням.
    @State private var range = MeterRange()
    /// Столбики встают волной, каждый следующий на 20 мс позже — эквалайзер «оживает»,
    /// а не возникает целиком.
    @State private var risen = false
    /// Сколько кадров этой записи уже ушло в журнал.
    @State private var traced = 0
    /// Когда началась эта запись: по нему шкала понимает, что микрофон ещё просыпается.
    @State private var started = Date()

    /// Стартовый кадр берём из первого же уровня, а не из нуля: иначе первая отрисовка
    /// (и статичная проба рендера) показывала бы штрихи тишины при живом звуке.
    init(level: Float, reduceMotion: Bool) {
        self.level = level
        self.reduceMotion = reduceMotion
        _frame = State(initialValue: Frame())
    }

    /// В тишине ряд не замирает плоской линией, а еле заметно дышит: молчащий эквалайзер
    /// выглядит зависшим, хотя приложение слушает. Порог низкий — дыхание не должно
    /// подмешиваться в настоящую речь.
    private var breathes: Bool {
        !reduceMotion && frame.heights.allSatisfy { $0 < 0.08 }
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
        // Линейная, а не затухающая: лента едет с постоянной скоростью, как конвейер.
        // Затухание в конце каждого шага и читалось как отдельный рывок двенадцать раз
        // в секунду. Одна анимация на весь ряд, никаких пружин с задержками по столбику.
        // Вес столбика — псевдослучайный и меняется на каждом замере: пружина начинает
        // догонять случайную цель, промахиваться и качаться обратно, у каждого столбика
        // в своей фазе, и ряд заметно дрожит. Инерция здесь не работает по построению.
        .animation(.linear(duration: 0.18), value: frame)
        .onChange(of: level) { _, new in
            let height = range.push(new, at: Date().timeIntervalSince(started))
            trace(level: new, height: height)
            frame.push(height)
        }
        // Волна разворачивается не в тот же миг, что и капсула: сначала на экран приезжает
        // стекло, и только потом внутри него раскрывается ряд. Без этой паузы нажатие ⌘
        // и появление волны сливаются в один кадр, и разглядеть движение невозможно.
        .onAppear {
            // Каждая запись начинается с чистого листа. Полагаться на то, что SwiftUI
            // создаст вью заново, нельзя: он вправе переиспользовать состояние вью в той же
            // позиции дерева, и тогда новая запись открывалась бы хвостом прошлой — то есть
            // громкой речью во весь рост. Шкала тоже своя: комната и микрофон могли смениться.
            frame = Frame()
            range = MeterRange()
            traced = 0
            started = Date()
            guard !reduceMotion else {
                risen = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { risen = true }
        }
    }

    /// Первые кадры записи — в журнал, уровнем `notice`: `debug` система
    /// в журнале не сохраняет, и прочитать его постфактум нельзя. Заведено после трёх заходов на жалобу «при включении всё на максимуме»:
    /// расчёт на сохранённых записях каждый раз показывал нормальную картину, а вживую
    /// человек видел другое, и свести одно с другим было нечем. Теперь есть чем:
    ///     log show --predicate 'subsystem == "online.nazarovych.cribe"' --last 5m
    private func trace(level: Float, height: CGFloat) {
        guard traced < Self.tracedFrames else { return }
        traced += 1
        Self.logger.notice(
            """
            кадр \(traced, privacy: .public): уровень \(level, format: .fixed(precision: 5), privacy: .public) \
            (\(20 * log10(max(level, .leastNormalMagnitude)), format: .fixed(precision: 1), privacy: .public) dBFS) \
            → высота \(height, format: .fixed(precision: 2), privacy: .public)
            """
        )
    }

    /// Сколько первых кадров записываем: полторы секунды с запасом.
    private static let tracedFrames = 20
    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Meter")

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
        let loudness = frame.heights[bar] + breath * breathDepth
        return minBar + min(1, loudness) * (maxBar - minBar)
    }

    /// Насколько высоко поднимается дыхание тишины. Больше — и молчащий эквалайзер начнёт
    /// притворяться, что слышит речь.
    private static let breathDepth: CGFloat = 0.035


    /// Акцентный градиент остаётся настоящим цветом поверх стекла — вибрантным его делать нельзя,
    /// иначе полоски выцветут в серые штрихи.
    private static let fill = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
        startPoint: .top,
        endPoint: .bottom
    )
}

