import Combine
import SwiftUI
import CribeCore

/// То немногое из конвейера, что нужно меню строки состояния.
///
/// Меню наблюдало сам `DictationController`, а тот на записи публикуется примерно двенадцать
/// раз в секунду: состояние `.recording` несёт уровень микрофона, и каждый кадр метра —
/// это сигнал всем подписчикам. Меню от уровня не зависит ни одной строкой, но подписка
/// об этом не знает.
///
/// Здесь поток сворачивается в две величины, каждая с `removeDuplicates()`: строку статуса
/// и «есть ли последняя диктовка». Двенадцать кадров в секунду превращаются в ноль сигналов,
/// пока текст статуса не поменяется.
@MainActor
final class MenuState: ObservableObject {
    @Published private(set) var status: String = ""
    /// Есть что копировать и что разбирать в словаре.
    @Published private(set) var hasDictation = false

    private var watch: Set<AnyCancellable> = []

    init(controller: DictationController, settings: AppSettings) {
        // Статус зависит и от состояния, и от языка с переводом — иначе строка «Готов ·
        // Русский» не менялась бы вслед за переключением языка в этом же меню.
        let status = Publishers.CombineLatest4(
            controller.$state,
            settings.$languages,
            settings.$translateToEnglish,
            settings.$translationTarget
        )
        .map { state, languages, translating, target in
            MenuStatusText.line(
                state: state,
                languages: controller.activeSessionLanguages ?? languages,
                translating: controller.activeSessionTranslate ?? translating,
                target: target
            )
        }
        .removeDuplicates()

        status.assign(to: &$status)

        controller.$lastOriginal
            .map { $0 != nil }
            .removeDuplicates()
            .assign(to: &$hasDictation)
    }
}

/// Слова статуса отдельно от вью: их проверяют тесты, и они же должны совпадать с капсулой.
enum MenuStatusText {
    static func line(
        state: DictationState,
        languages: Set<Language>,
        translating: Bool,
        target: TranslationTarget = .en
    ) -> String {
        let named = Language.displayName(of: languages)
        switch state {
        case .idle: return "Готов · \(named)"
        case .preparingModel(.downloading(let progress)): return "Качаю модель… \(Int(progress * 100))%"
        case .preparingModel(.warming): return "Готовлю модель…"
        // Уровень намеренно не участвует: строка на записи не меняется вовсе, и подписчики
        // меню на потоке метра не просыпаются.
        // Код цели, а не вписанное «EN»: с выбором языка перевода строка писала «→ EN»
        // и тогда, когда диктовка уходила на польский.
        case .recording:
            return "● Идёт запись · \(named)\(translating ? " → \(target.rawValue.uppercased())" : "")"
        case .transcribing: return "Распознаю…"
        // Тем же словом, что и капсула: переводящая диктовка не чистится, а переводится.
        case .cleaning: return translating ? "🌐 Перевожу…" : "✨ Чищу…"
        case .inserted: return "✓ Вставлено"
        case .carded: return "⤷ В карточку"
        case .cancelled: return "✕ Отменено"
        case .degraded(let reason): return "⚠️ \(reason)"
        case .error(let message): return "⚠️ \(message)"
        }
    }
}
