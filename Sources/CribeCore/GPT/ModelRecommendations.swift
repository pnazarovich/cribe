import Foundation

/// Подсказка «что выбрать» для настроек: одна строка на уровень.
public struct ModelRecommendation: Identifiable, Sendable {
    public enum Tier: String, Sendable {
        case speed
        case balance
        case quality

        public var emoji: String {
            switch self {
            case .speed: return "⚡"
            case .balance: return "⚖️"
            case .quality: return "💎"
            }
        }

        public var title: String {
            switch self {
            case .speed: return "Скорость"
            case .balance: return "Баланс"
            case .quality: return "Качество"
            }
        }
    }

    public let tier: Tier
    public let model: String
    /// Усилие рассуждения, рекомендованное именно для этой пары «модель + режим».
    public let effort: String
    public let note: String

    public var id: String { tier.rawValue }
}

/// Статичная таблица рекомендаций (замеры середины 2026). Дефолты `GPTConfig` не трогает:
/// пользователь применяет строку вручную кнопкой «Выбрать».
public enum ModelRecommendations {

    /// Всегда три уровня в порядке скорость → баланс → качество.
    public static func list(for mode: GPTAuthMode) -> [ModelRecommendation] {
        switch mode {
        case .apiKey:
            // Публичный API считает деньги, а не квоту, поэтому reasoning выключаем совсем.
            return [
                ModelRecommendation(
                    tier: .speed,
                    model: "gpt-5.6-luna",
                    effort: "none",
                    note: "~1.5–2 с на диктовку, ≈$0.001. Самая быстрая."
                ),
                ModelRecommendation(
                    tier: .balance,
                    model: "gpt-5.6-terra",
                    effort: "none",
                    note: "~2 с, ≈$0.005. Качество уровня 5.5, надёжнее на словаре и переводе."
                ),
                ModelRecommendation(
                    tier: .quality,
                    model: "gpt-5.6-sol",
                    effort: "none",
                    note: "~3.5–4 с, ≈$0.01. Фронтир: точнее всего правит, не переписывая."
                ),
            ]
        case .codex:
            // Codex-бэкенд ниже `low` не опускается — это минимум, который он примет.
            return [
                ModelRecommendation(
                    tier: .speed,
                    model: "gpt-5.6-luna",
                    effort: "low",
                    note: "Экономит квоту Plus, но НЕ быстрее: замер дал 3,9 с против 2,5 с "
                        + "у Terra, и качество ниже."
                ),
                ModelRecommendation(
                    tier: .balance,
                    model: "gpt-5.6-terra",
                    effort: "low",
                    note: "~2,5 с — быстрее всех по замеру, качество без потерь и меньший "
                        + "расход квоты, чем у Sol."
                ),
                ModelRecommendation(
                    tier: .quality,
                    model: "gpt-5.6-sol",
                    effort: "low",
                    note: "~4–5 с. Фронтир; квота тает в 5 раз быстрее Luna — для важных текстов."
                ),
            ]
        }
    }

    public static let disclaimer =
        "Оценки — медианы бенчмарков (сер. 2026); реальная скорость зависит от нагрузки OpenAI."
}
