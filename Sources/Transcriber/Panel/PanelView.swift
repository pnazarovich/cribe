import AppKit
import SwiftUI
import TranscriberCore

/// Содержимое живой панели: одна маленькая пилюля у нижнего края экрана.
/// Пересобирается на каждое обновление уровня (~12 раз в секунду), поэтому дерево держим плоским.
struct PanelView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    private var isVisible: Bool {
        if case .idle = controller.state { return false }
        return true
    }

    var body: some View {
        Group {
            if isVisible {
                PanelPill(
                    state: controller.state,
                    // Язык идущей сессии, а не настройки: переключение на живой записи её не меняет.
                    language: controller.activeSessionLanguage ?? settings.language,
                    // Перевод сессии, а не настройки: правый ⌥ переводит вопреки выключенному
                    // тумблеру. Без переопределения (nil) всё как раньше — по тумблеру.
                    translateToEnglish: controller.activeSessionTranslate ?? settings.translateToEnglish
                )
                // Не подмена вью, а морф той же капсулы: она вырастает из себя и в себя уходит.
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        // Появление резче ухода: снаппи на входе, гладко на выходе.
        .animation(isVisible ? .snappy(duration: 0.4) : .smooth(duration: 0.4), value: isVisible)
        // Окно больше пилюли: лишнее пространство прозрачно, пилюля висит по центру.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Настройки Универсального доступа, от которых зависит вид панели. Системное уведомление
/// приходит и когда приложение неактивно, поэтому подложка переключается вживую.
@MainActor
final class HUDAccessibility: ObservableObject {
    static let shared = HUDAccessibility()

    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var reduceMotion: Bool
    @Published private(set) var increaseContrast: Bool

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        // Наблюдателя не снимаем: объект живёт столько же, сколько приложение.
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Уведомление доставляется на главную очередь — это и есть MainActor.
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}

/// Пилюля без наблюдаемых объектов: то же дерево рисует и проба ImageRenderer,
/// которой неоткуда взять контроллер в нужном состоянии.
///
/// Стек слоёв снизу вверх: материал за окном → тёмный скрим → контент → волосяной кант →
/// верхний блик → двойная тень. Один слой стекла, без шума и без стекла на стекле.
/// Радиус — строго половина высоты (22), его даёт сама `Capsule()`; вложенные скругления
/// концентрические: 22 минус отступ от края.
struct PanelPill: View {
    let state: DictationState
    let language: Language
    let translateToEnglish: Bool

    @ObservedObject private var accessibility = HUDAccessibility.shared

    /// Габарит пилюли: один и тот же для записи и всех состояний обработки —
    /// панель не должна «дышать» размером на каждом шаге конвейера.
    static let width: CGFloat = 190
    static let height: CGFloat = 44
    /// Потолок ширины: сообщение об ошибке длиннее ярлыка, но панель всё равно остаётся маленькой.
    private static let maxWidth: CGFloat = 320

    var body: some View {
        content
            // Средний вес, а не тонкий: на полупрозрачном фоне тонкий шрифт плывёт.
            .font(.system(size: 12, weight: .medium))
            // Длинная ошибка переносится, но выше двух строк пилюля не растёт.
            .lineLimit(2)
            .padding(.horizontal, 14)
            .frame(minWidth: Self.width, maxWidth: Self.maxWidth, minHeight: Self.height)
            // Без `fixedSize` рамка забирает всю предложенную ширину окна и пилюля всегда
            // раздувается до потолка: измерено пробой (190/320 против 320/320).
            .fixedSize(horizontal: true, vertical: false)
            .background { glass }
            .overlay { rim }
            .overlay { sheen }
            // Без группировки тень рисовалась бы от каждого сабвью отдельно.
            .compositingGroup()
            // Две тени: широкая мягкая продаёт парение, плотная контактная даёт кромку.
            .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
            .shadow(color: .black.opacity(0.20), radius: 2.5, y: 1)
            // Схема фиксированно тёмная: только она читается над любым фоном — и над белым
            // документом, и над видео. Адаптивная полярность здесь только мигала бы.
            .environment(\.colorScheme, .dark)
            // Ширина меняется на смене состояния — и только на ней: поток уровня не морфит.
            .animation(.snappy(duration: 0.4), value: morphKey)
    }

    /// Слои 1–2: материал, сэмплирующий содержимое за окном, и тёмный скрим поверх него.
    /// Скрим — то, что делает контент читаемым над белым фоном; выше 0.25 стекло умирает.
    @ViewBuilder
    private var glass: some View {
        if accessibility.reduceTransparency {
            // Фолбэк без прозрачности: сплошная тёмная пилюля, всё остальное как было.
            Capsule().fill(Color(white: 0.12))
        } else {
            ZStack {
                HUDBackdrop()
                Capsule().fill(.black.opacity(accessibility.increaseContrast ? 0.30 : 0.22))
            }
        }
    }

    /// Слой 4: волосяной кант в 1 px, светлый сверху и почти прозрачный снизу.
    /// Именно асимметрия отличает стекло от «картинной рамы» равномерной обводки.
    @ViewBuilder
    private var rim: some View {
        if accessibility.reduceTransparency || accessibility.increaseContrast {
            Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)
        } else {
            Capsule().strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.45), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.4),
                        .init(color: .white.opacity(0.06), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
    }

    /// Слой 5: внутренний блик — размытая дуга по верхней кромке, гаснущая к середине.
    private var sheen: some View {
        Capsule()
            .inset(by: 1)
            .stroke(.white.opacity(0.15), lineWidth: 0.5)
            .blur(radius: 1)
            .mask { LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center) }
    }

    /// Ключ морфа: различает состояния, но не уровень внутри `.recording` —
    /// иначе анимация ширины перезапускалась бы 12 раз в секунду.
    private var morphKey: Int {
        switch state {
        case .idle: 0
        case .preparingModel: 1
        case .recording: 2
        case .transcribing: 3
        case .cleaning: 4
        case .inserted: 5
        case .cancelled: 6
        case .degraded: 7
        case .error: 8
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()

        case .preparingModel(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("Загружаю…")
            }

        case .recording(_, let level):
            // Живого текста в панели нет: только индикатор, язык, метка перевода и эквалайзер.
            HStack(spacing: 8) {
                RecordingDot(reduceMotion: accessibility.reduceMotion)
                Text(Self.flag(language))
                if translateToEnglish {
                    TranslationBadge()
                }
                EqualizerView(level: level)
                // Единственная подсказка про отмену. Тише всего, что есть в пилюле, и
                // постоянной ширины — на потоке уровня (~12 раз в секунду) она не дёргается.
                // Белый с прозрачностью, не акцентный цвет: мелкий цветной текст на стекле грязнит.
                Text("esc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .transcribing:
            spinnerRow("Распознаю…")

        case .cleaning:
            spinnerRow("✨ Чищу…")

        case .inserted:
            // Зелёная вспышка удачи: цвет плюс короткое свечение по контуру текста.
            Text("✓ Вставлено")
                .foregroundStyle(Color.green)
                .shadow(color: .green.opacity(0.45), radius: 4)

        case .cancelled:
            Text("✕ Отменено")

        case .degraded(let reason):
            Text("⚠️ \(Self.reasonText(reason))")

        case .error(let message):
            Text("⚠️ \(message)")
                .foregroundStyle(Color.red)
        }
    }

    private func spinnerRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.blue)
            Text(text)
        }
    }

    private static func flag(_ language: Language) -> String {
        language == .ru ? "🇷🇺" : "🇺🇦"
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

/// Слой 1: единственный слой стекла — системный материал, который блюрит содержимое ЗА окном.
/// SwiftUI-материалы (`.ultraThinMaterial` и прочие) на macOS фон за окном не видят и дают
/// плоскую серую плашку, поэтому подложка тут именно AppKit-овая.
private struct HUDBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = CapsuleEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // Ключевая строка: панель никогда не становится key, а `.active` не даёт стеклу потухнуть.
        view.state = .active
        view.isEmphasized = true
        // Материал берёт вариант из оформления вью, а пилюля всегда тёмная.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Форму материалу задаёт только `maskImage`: слой, который рисует WindowServer, надёжно не режут
/// ни `clipShape`, ни CALayer-маска. Маска — растягиваемая 9-частная капсула, поэтому одна
/// картинка годится на любую ширину пилюли; пересобираем её лишь при смене высоты.
private final class CapsuleEffectView: NSVisualEffectView {
    private var maskedHeight: CGFloat = 0

    override func layout() {
        super.layout()
        guard bounds.height > 0, abs(bounds.height - maskedHeight) > 0.5 else { return }
        maskedHeight = bounds.height
        maskImage = .capsuleMask(height: bounds.height)
    }
}

extension NSImage {
    /// Сторона 2r+1: центральная полоса шириной в точку, её растяжение и даёт капсулу
    /// любой ширины с неискажёнными торцами.
    fileprivate static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Индикатор записи: настоящий красный, а не семантический стиль — иерархические стили на стекле
/// обесцвечиваются. Белое свечение держит точку заметной и поверх тёмного видео.
private struct RecordingDot: View {
    let reduceMotion: Bool

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: .white.opacity(0.25), radius: 3)
            // Пульс только по трансформации и прозрачности; покой — полный красный кружок,
            // поэтому при «Уменьшить движение» точка просто остаётся статичной.
            // Дно прозрачности высокое (0.8): на просвет точка не должна тускнеть до бурой.
            .scaleEffect(pulsing ? 1.18 : 1)
            .opacity(pulsing ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = !reduceMotion }
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

    private static let barCount = 12
    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 4
    private static let maxBar: CGFloat = 22
    /// Столбик тишины — короткий штрих, а не пустое место.
    private static let minBar: CGFloat = 2.5

    /// Уровень и номер тика меняются одним присваиванием: иначе анимация ловила бы
    /// смену высот двумя рывками — сначала уровень, потом веса.
    private struct Frame: Equatable {
        var tick: Int
        var level: Float
    }

    @State private var frame: Frame

    /// Стартовый кадр берём из первого же уровня, а не из нуля: иначе первая отрисовка
    /// (и статичная проба рендера) показывала бы штрихи тишины при живом звуке.
    init(level: Float) {
        self.level = level
        _frame = State(initialValue: Frame(tick: 0, level: level))
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Self.fill)
                    .frame(width: Self.barWidth, height: Self.barHeight(bar: index, frame: frame))
            }
        }
        // Симметрия относительно средней линии: столбики центрируются по высоте полосы.
        .frame(height: Self.maxBar)
        .animation(.easeOut(duration: 0.1), value: frame)
        .onChange(of: level) { _, new in
            frame = Frame(tick: frame.tick &+ 1, level: new)
        }
    }

    /// RMS речи обычно 0.02…0.2 — тянем перцептивно: тихая речь всё равно шевелит эквалайзер,
    /// а громкая не упирается в полку.
    private static func barHeight(bar: Int, frame: Frame) -> CGFloat {
        let norm = min(1, pow(max(frame.level, 0) * 6, 0.7))
        return minBar + CGFloat(norm) * weight(bar: bar, tick: frame.tick) * (maxBar - minBar)
    }

    /// Вес столбика 0.35…1 — детерминированный хеш пары (столбик, тик): разброс выглядит
    /// случайным, но один и тот же кадр всегда рисуется одинаково (важно для пробы рендера).
    private static func weight(bar: Int, tick: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: tick) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(truncatingIfNeeded: bar) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 30
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        // Старшие 24 бита → доля 0…1.
        return 0.35 + CGFloat(x >> 40) / CGFloat(1 << 24) * 0.65
    }

    /// Акцентный градиент остаётся настоящим цветом поверх стекла — вибрантным его делать нельзя,
    /// иначе полоски выцветут в серые штрихи.
    private static let fill = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
        startPoint: .top,
        endPoint: .bottom
    )
}
