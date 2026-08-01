import SwiftUI
import TranscriberCore

/// Содержимое живой панели: одна маленькая пилюля у нижнего края экрана.
/// Пересобирается на каждое обновление уровня (~12 раз в секунду), поэтому дерево держим плоским.
struct PanelView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            if case .idle = controller.state {
                EmptyView()
            } else {
                PanelPill(
                    state: controller.state,
                    // Язык идущей сессии, а не настройки: переключение на живой записи её не меняет.
                    language: controller.activeSessionLanguage ?? settings.language,
                    // Перевод сессии, а не настройки: правый ⌥ переводит вопреки выключенному
                    // тумблеру. Без переопределения (nil) всё как раньше — по тумблеру.
                    translateToEnglish: controller.activeSessionTranslate ?? settings.translateToEnglish
                )
            }
        }
        // Окно больше пилюли: лишнее пространство прозрачно, пилюля висит по центру.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Пилюля без наблюдаемых объектов: то же дерево рисует и проба ImageRenderer,
/// которой неоткуда взять контроллер в нужном состоянии.
struct PanelPill: View {
    let state: DictationState
    let language: Language
    let translateToEnglish: Bool

    /// Габарит пилюли: один и тот же для записи и всех состояний обработки —
    /// панель не должна «дышать» размером на каждом шаге конвейера.
    static let width: CGFloat = 190
    static let height: CGFloat = 44
    /// Потолок ширины: сообщение об ошибке длиннее ярлыка, но панель всё равно остаётся маленькой.
    private static let maxWidth: CGFloat = 320

    var body: some View {
        content
            .font(.system(size: 12))
            // Длинная ошибка переносится, но выше двух строк пилюля не растёт.
            .lineLimit(2)
            .padding(.horizontal, 14)
            .frame(minWidth: Self.width, maxWidth: Self.maxWidth, minHeight: Self.height)
            // Без `fixedSize` рамка забирает всю предложенную ширину окна и пилюля всегда
            // раздувается до потолка: измерено пробой (190/320 против 320/320).
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial, in: Capsule())
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
            // Живого текста в панели нет: только язык, метка перевода и эквалайзер.
            HStack(spacing: 8) {
                Text(Self.flag(language))
                if translateToEnglish {
                    TranslationBadge()
                }
                EqualizerView(level: level)
            }

        case .transcribing:
            spinnerRow("Распознаю…")

        case .cleaning:
            spinnerRow("✨ Чищу…")

        case .inserted:
            Text("✓ Вставлено")

        case .degraded(let reason):
            Text("⚠️ \(Self.reasonText(reason))")

        case .error(let message):
            Text("⚠️ \(message)")
        }
    }

    private func spinnerRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
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

/// Метка «перевод на английский включён»: результат придёт не на языке записи.
private struct TranslationBadge: View {
    var body: some View {
        Text("→ EN")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
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

    private static let fill = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
        startPoint: .top,
        endPoint: .bottom
    )
}
