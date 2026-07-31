import Combine
import Foundation

/// Чем запускается диктовка: «голым» правым ⌘ или своим шорткатом.
public enum HotkeyMode: String, Codable, CaseIterable, Sendable {
    case rightCommand
    case custom
}

/// Настройки приложения поверх UserDefaults. Каждое поле пишется на диск при изменении,
/// UI подписан через `@Published`.
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private enum Key {
        static let language = "language"
        static let gptEnabled = "gptEnabled"
        static let gptMode = "gptMode"
        static let gptModel = "gptModel"
        static let gptEffort = "gptEffort"
        static let inputDeviceUID = "inputDeviceUID"
        static let translateToEnglish = "translateToEnglish"
        static let soundsEnabled = "soundsEnabled"
        static let autoStopEnabled = "autoStopEnabled"
        static let dictationHotkeyMode = "dictationHotkeyMode"
        static let skipGPTForShort = "skipGPTForShort"
        static let shortDictationWordLimit = "shortDictationWordLimit"
    }

    private let defaults: UserDefaults

    @Published public var language: Language {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    @Published public var gptEnabled: Bool {
        didSet { defaults.set(gptEnabled, forKey: Key.gptEnabled) }
    }

    @Published public var gptMode: GPTAuthMode {
        didSet { defaults.set(gptMode.rawValue, forKey: Key.gptMode) }
    }

    @Published public var gptModel: String {
        didSet { defaults.set(gptModel, forKey: Key.gptModel) }
    }

    /// "none" | "minimal" | "low" | "medium" | "high"
    @Published public var gptEffort: String {
        didSet { defaults.set(gptEffort, forKey: Key.gptEffort) }
    }

    /// Диктовка вставляется переводом на английский (GPT-слой переводит вместо простой чистки).
    @Published public var translateToEnglish: Bool {
        didSet { defaults.set(translateToEnglish, forKey: Key.translateToEnglish) }
    }

    /// Чаймы старта и окончания записи.
    @Published public var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) }
    }

    /// Останавливать запись самой после 2 с тишины. По умолчанию выключено: запись
    /// выключается только повторным нажатием хоткея.
    @Published public var autoStopEnabled: Bool {
        didSet { defaults.set(autoStopEnabled, forKey: Key.autoStopEnabled) }
    }

    /// Короткая диктовка идёт мимо GPT-слоя: на «ок» или «да, давай» чистка ничего не меняет,
    /// зато стоит целый круг к модели. Перевода это не касается — он делается тем же вызовом.
    @Published public var skipGPTForShort: Bool {
        didSet { defaults.set(skipGPTForShort, forKey: Key.skipGPTForShort) }
    }

    /// Граница «короткой» диктовки в словах.
    @Published public var shortDictationWordLimit: Int {
        didSet { defaults.set(shortDictationWordLimit, forKey: Key.shortDictationWordLimit) }
    }

    /// Кнопка записи: правый ⌘ (по умолчанию) или шорткат из KeyboardShortcuts.
    @Published public var dictationHotkeyMode: HotkeyMode {
        didSet { defaults.set(dictationHotkeyMode.rawValue, forKey: Key.dictationHotkeyMode) }
    }

    /// UID выбранного микрофона; nil — системный по умолчанию (nil стирает ключ).
    @Published public var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    public var gptConfig: GPTConfig {
        GPTConfig(mode: gptMode, model: gptModel, effort: gptEffort)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Key.language).flatMap(Language.init(rawValue:)) ?? .ru
        gptEnabled = defaults.object(forKey: Key.gptEnabled) as? Bool ?? true
        let mode = defaults.string(forKey: Key.gptMode).flatMap(GPTAuthMode.init(rawValue:)) ?? .codex
        gptMode = mode
        gptModel = defaults.string(forKey: Key.gptModel) ?? GPTConfig.defaultModel(for: mode)
        gptEffort = defaults.string(forKey: Key.gptEffort) ?? GPTConfig.defaultEffort
        translateToEnglish = defaults.bool(forKey: Key.translateToEnglish)
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        autoStopEnabled = defaults.object(forKey: Key.autoStopEnabled) as? Bool ?? false
        skipGPTForShort = defaults.object(forKey: Key.skipGPTForShort) as? Bool ?? true
        shortDictationWordLimit = defaults.object(forKey: Key.shortDictationWordLimit) as? Int ?? 8
        dictationHotkeyMode = defaults.string(forKey: Key.dictationHotkeyMode)
            .flatMap(HotkeyMode.init(rawValue:)) ?? .rightCommand
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
    }
}
