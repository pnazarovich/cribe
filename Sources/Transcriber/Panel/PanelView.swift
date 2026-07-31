import SwiftUI
import TranscriberCore

/// Содержимое живой панели: одна капсула у нижнего края экрана.
/// Пересобирается на каждое обновление уровня (~12 раз в секунду), поэтому дерево держим плоским.
struct PanelView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    /// Хвост после последнего законченного предложения — «сырая» часть превью, её красим серым.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]

    var body: some View {
        Group {
            if case .idle = controller.state {
                EmptyView()
            } else {
                capsule
            }
        }
        // Окно выше капсулы: лишнее пространство прозрачно, капсула прижата к его низу.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var capsule: some View {
        content
            .font(.system(size: 13))
            // Общий потолок высоты: длинное сообщение об ошибке не должно раздувать капсулу.
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            EmptyView()

        case .preparingModel(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text("Загружаю модель…")
            }

        case .recording(let live, let level):
            // Волна занимает верхнюю строку целиком, превью идёт под ней.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    PulsingDot()
                    // Язык идущей сессии, а не настройки: переключение на живой записи её не меняет.
                    Text(Self.flag(controller.activeSessionLanguage ?? settings.language))
                    if settings.translateToEnglish {
                        TranslationBadge()
                    }
                    WaveformView(level: level)
                }
                liveText(live)
            }

        case .transcribing:
            spinnerRow("Распознаю…")

        case .cleaning:
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("✨ Чищу…")
                if settings.translateToEnglish {
                    TranslationBadge()
                }
            }

        case .inserted:
            Text("✓ Вставлено")

        case .degraded(let reason):
            Text("⚠️ \(Self.reasonText(reason))")

        case .error(let message):
            Text(message)
        }
    }

    private func spinnerRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text(text)
        }
    }

    @ViewBuilder
    private func liveText(_ text: String) -> some View {
        if text.isEmpty {
            Text("Слушаю…").foregroundStyle(.secondary)
        } else {
            let parts = Self.split(text)
            // Обрезаем начало: на экране всегда последние строки превью.
            (Text(parts.settled) + Text(parts.tail).foregroundStyle(.secondary))
                .lineLimit(3)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
        }
    }

    private static func split(_ text: String) -> (settled: String, tail: String) {
        guard let last = text.lastIndex(where: { sentenceEnders.contains($0) }) else { return ("", text) }
        let boundary = text.index(after: last)
        return (String(text[..<boundary]), String(text[boundary...]))
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
            // Иначе капсула перевода схлопнется под длинным превью.
            .fixedSize()
    }
}

/// Красная точка записи. Отдельный вью — чтобы анимация не перезапускалась при обновлении уровня.
private struct PulsingDot: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// Бегущая волна голоса: столбики уровня растут от средней линии в обе стороны,
/// новый уровень дописывается справа, самый старый уезжает влево.
/// Историю держит у себя (как PulsingDot — свою анимацию): пересборка панели её не сбрасывает.
private struct WaveformView: View {
    let level: Float

    private static let barCount = 48
    private static let barWidth: CGFloat = 3
    /// Минимальный зазор: при широкой капсуле столбики расходятся, ширина остаётся прежней.
    private static let spacing: CGFloat = 2
    private static let maxBar: CGFloat = 32
    /// Столбик тишины — короткий штрих, а не пустое место.
    private static let minBar: CGFloat = 2
    /// Сколько последних столбиков подсвечены ярче — «голова» волны.
    private static let freshCount = 4

    @State private var history = [Float](repeating: 0, count: WaveformView.barCount)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(Self.fill)
                    .frame(width: Self.barWidth, height: Self.barHeight(history[index]))
                    .opacity(index >= Self.barCount - Self.freshCount ? 1 : 0.65)
                if index < Self.barCount - 1 {
                    Spacer(minLength: Self.spacing)
                }
            }
        }
        .frame(height: Self.maxBar)
        .animation(.easeOut(duration: 0.08), value: history)
        // Именно на смену уровня: обновление одного live-текста волну сдвигать не должно.
        .onChange(of: level) { _, new in
            history.removeFirst()
            history.append(new)
        }
    }

    /// RMS речи обычно 0.02…0.2 — тянем перцептивно: тихая речь всё равно шевелит волну,
    /// а громкая не упирается в полку.
    private static func barHeight(_ level: Float) -> CGFloat {
        let norm = min(1, pow(max(level, 0) * 6, 0.7))
        return minBar + CGFloat(norm) * (maxBar - minBar)
    }

    private static let fill = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
        startPoint: .top,
        endPoint: .bottom
    )
}
