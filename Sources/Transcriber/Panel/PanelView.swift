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
            HStack(spacing: 10) {
                PulsingDot()
                Text(Self.flag(settings.language))
                liveText(live)
                LevelBar(level: level)
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

    /// Контроллер отдаёт причину уже по-русски; сырые технические коды подстраховываем здесь.
    private static func reasonText(_ reason: String) -> String {
        switch reason {
        case "secure input": return "Защищённое поле — нажмите ⌘V"
        case "no accessibility": return "Нет разрешения Accessibility"
        default: return reason
        }
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

/// Индикатор громкости. RMS речи обычно 0.02…0.2 — растягиваем диапазон, иначе полоска не шевелится.
private struct LevelBar: View {
    let level: Float

    private static let width: CGFloat = 44

    var body: some View {
        let filled = Self.width * CGFloat(min(max(level * 4, 0), 1))
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary).frame(width: Self.width, height: 4)
            Capsule().fill(.secondary).frame(width: filled, height: 4)
        }
    }
}
