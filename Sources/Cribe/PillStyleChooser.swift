import SwiftUI
import CribeCore

/// Выбор того, что показывает капсула на записи: волна или бегущая строка.
///
/// Две карточки с ЖИВЫМ примером, а не два слова в пикере. Выбирают тут не настройку,
/// а внешний вид — описать его словами нельзя, а увидеть можно за секунду. Примеры собраны
/// из тех же вью, что работают в настоящей капсуле (`EqualizerView`, `LiveTicker`):
/// нарисованная отдельно «похожая» картинка со временем разошлась бы с правдой.
///
/// Один компонент на три места — настройки, онбординг и экран обновления, — потому что
/// вопрос везде один и тот же.
struct PillStyleChooser: View {
    @Binding var selection: PillStyle

    var body: some View {
        HStack(spacing: 12) {
            card(.wave, title: "Волна", note: "Столбики громкости")
            card(.words, title: "Бегущая строка", note: "Слова по мере речи")
        }
    }

    private func card(_ style: PillStyle, title: String, note: String) -> some View {
        let selected = selection == style

        return Button {
            selection = style
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PillStylePreview(style: style)
                HStack(spacing: 6) {
                    Text(title)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.callout)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Кусочек настоящей капсулы: тёмная плашка и внутри — то самое, что будет на записи.
///
/// Примеру нужен вход, которого в покое нет: волне — уровень микрофона, строке — слова.
/// И то и другое здесь подделано временем, и это единственное, что в примере ненастоящее.
private struct PillStylePreview: View {
    let style: PillStyle

    @ObservedObject private var accessibility = HUDAccessibility.shared

    /// Фраза набирается по слову, как её отдавало бы распознавание, и начинается заново.
    /// Слова обычные, рабочие: пример должен быть похож на то, что человек диктует, а
    /// не на «lorem ipsum».
    private static let words = [
        "проверь", "webhooks", "и", "nginx", "потом", "задеплой", "на", "Vercel",
    ]

    /// Сколько держится каждое слово. Примерно тот же темп, что у настоящего предпросмотра
    /// (проход раз в 0,9 с), — иначе пример обещал бы скорость, которой не будет.
    private static let wordSeconds = 0.9

    var body: some View {
        ZStack {
            Capsule().fill(Color.black.opacity(0.55))
            Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            content
        }
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        // Замирающий пример не показывает главного — движения. Поэтому кадры идут даже при
        // «Уменьшить движение»: это картинка внутри окна настроек, а не всплывающая панель.
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            switch style {
            case .wave:
                EqualizerView(
                    level: Self.level(at: seconds),
                    reduceMotion: accessibility.reduceMotion
                )
            case .words:
                // Отступ по краям — слот в настоящей капсуле теперь тянущийся, и без него
                // строка упёрлась бы в торец плашки.
                LiveTicker(text: Self.phrase(at: seconds), reduceMotion: false)
                    .padding(.horizontal, 14)
            }
        }
    }

    /// Правдоподобный уровень: две несоизмеримые синусоиды дают речь, а не метроном.
    private static func level(at seconds: TimeInterval) -> Float {
        let slow = sin(seconds * 2.1)
        let fast = sin(seconds * 7.3)
        return Float(max(0.02, 0.22 + 0.16 * slow + 0.08 * fast))
    }

    private static func phrase(at seconds: TimeInterval) -> String {
        let step = Int(seconds / wordSeconds) % (words.count + 2)
        // С четырёх, а не с одного: настоящая капсула показывает строку не раньше четвёртого
        // слова (`DictationController.livePreviewMinimumWords`), и пример обязан начинаться там же.
        return words.prefix(max(4, step)).joined(separator: " ")
    }
}
