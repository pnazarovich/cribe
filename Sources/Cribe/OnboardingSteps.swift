import Foundation

/// Как выглядит шаг первого запуска: ждёт очереди, идёт сейчас или уже сделан.
enum OnboardingStepState {
    case pending
    case active
    case done
}

/// Шаги первого запуска в порядке показа.
///
/// Приветствие и клавиши живут в шапке окна, а не строкой списка: делать в них нечего,
/// а галочка у того, что нельзя не выполнить, обесценивает остальные.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case models
    case ai
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Микрофон"
        case .accessibility: return "Универсальный доступ"
        case .models: return "Модели распознавания"
        case .ai: return "ChatGPT — чистка и перевод"
        case .ready: return "Готово"
        }
    }

    /// Без чего диктовка не работает вообще.
    ///
    /// Моделей здесь нет намеренно: не скачал — первая диктовка дотянет модель сама, и
    /// держать за это окно закрытым не за что. ChatGPT — тем более: без него текст
    /// распознаётся и вставляется, просто без знаков препинания от GPT.
    static let required: [OnboardingStep] = [.microphone, .accessibility]

    /// Шаги, которые можно отложить кнопкой. Очередь они держат ровно до этого нажатия.
    static let skippable: [OnboardingStep] = [.models, .ai]

    /// Порядок прохождения — всё, кроме финиша.
    static let ordered: [OnboardingStep] = [.microphone, .accessibility, .models, .ai]
}

/// Что из первого запуска уже сделано. Отдельно от вью: состояние шагов — это правила,
/// а не разметка, и проверять их надо числами, а не глазами.
struct OnboardingProgress: Equatable {
    var micGranted = false
    var accessibilityGranted = false
    /// Хотя бы одна модель уже лежит на диске.
    var modelInstalled = false
    var gptAuthorized = false
    /// Нажато «Позже» на моделях.
    var modelsSkipped = false
    /// Нажато «Пропустить» на ChatGPT.
    var aiSkipped = false

    func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: return micGranted
        case .accessibility: return accessibilityGranted
        case .models: return modelInstalled
        case .ai: return gptAuthorized
        // «Готово» — не задание, а финишная черта: галочки у неё не бывает.
        case .ready: return false
        }
    }

    /// Шаг больше не ждёт пользователя: сделан или отложен.
    func isSettled(_ step: OnboardingStep) -> Bool {
        if isDone(step) { return true }
        switch step {
        case .models: return modelsSkipped
        case .ai: return aiSkipped
        default: return false
        }
    }

    /// Шаг, который идёт сейчас, — первый неулаженный. Необязательные держат очередь до
    /// своего «Позже»/«Пропустить»: иначе финиш светился бы недостижимым тому, кто модель
    /// качать сейчас не хочет.
    var activeStep: OnboardingStep {
        OnboardingStep.ordered.first { !isSettled($0) } ?? .ready
    }

    func state(of step: OnboardingStep) -> OnboardingStepState {
        if isDone(step) { return .done }
        return step == activeStep ? .active : .pending
    }

    /// Диктовкой уже можно пользоваться: всё обязательное выдано.
    var isUsable: Bool {
        OnboardingStep.required.allSatisfy(isDone)
    }
}
