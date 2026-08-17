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

    /// Модель перевода по умолчанию.
    public static let defaultTranslateModel = "gpt-5.6-terra"

    /// Усилие рассуждения на чистке. Выше общего дефолта `GPTConfig`: чистка живой речи —
    /// не разметка текста, ей нужно понять, где кончилась мысль, а не только расставить точки.
    public static let defaultCleanupEffort = "medium"

    /// Усилие рассуждения на переводе. Ещё выше: тот же вызов и чистит, и переводит,
    /// и ошибка перевода стоит дороже пропущенной запятой.
    public static let defaultTranslateEffort = "high"

    private enum Key {
        static let language = "language"
        static let gptEnabled = "gptEnabled"
        static let gptMode = "gptMode"
        static let gptModel = "gptModel"
        static let gptEffort = "gptEffort"
        static let translateModel = "translateModel"
        static let translateEffort = "translateEffort"
        static let inputDeviceUID = "inputDeviceUID"
        static let translateToEnglish = "translateToEnglish"
        static let soundsEnabled = "soundsEnabled"
        static let autoStopEnabled = "autoStopEnabled"
        static let dictationHotkeyMode = "dictationHotkeyMode"
        static let skipGPTForShort = "skipGPTForShort"
        static let restoreUkrainianInserts = "restoreUkrainianInserts"
        static let catchesNeighbourLanguage = "catchesNeighbourLanguage"
        static let shortDictationWordLimit = "shortDictationWordLimit"
        static let learnsFromEdits = "learnsFromEdits"
        static let recognitionEngine = "recognitionEngine"
        static let cardsWhenNoField = "cardsWhenNoField"
        static let keptRecordings = "keptRecordings"
        static let dictationsStarted = "dictationsStarted"
        static let parallelHintShown = "parallelHintShown"
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

    /// Модель для перевода — своя: чистке хватает быстрой модели, а перевод (тот же вызов
    /// чистит и переводит) выигрывает от модели покрупнее.
    @Published public var translateModel: String {
        didSet { defaults.set(translateModel, forKey: Key.translateModel) }
    }

    /// Усилие рассуждения на переводе; шкала та же, что у `gptEffort`.
    @Published public var translateEffort: String {
        didSet { defaults.set(translateEffort, forKey: Key.translateEffort) }
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

    /// Русская диктовка с украинскими вставками: чистка возвращает украинским словам,
    /// которые распознавание записало на слух по-русски, украинское написание. Работает
    /// только на русских сессиях и только на чистке — на переводе текст уедет в английский.
    @Published public var restoreUkrainianInserts: Bool {
        didSet { defaults.set(restoreUkrainianInserts, forKey: Key.restoreUkrainianInserts) }
    }

    /// Перечитывать ли фразы, которые звучат не на языке сессии. Русская диктовка
    /// с украинской фразой внутри выходит фонетическим мусором, и спасти её может только
    /// повторное чтение этой фразы украинской моделью (см. `SecondOpinion`). Стоит времени,
    /// поэтому спрашиваем, а не включаем всем.
    @Published public var catchesNeighbourLanguage: Bool {
        didSet { defaults.set(catchesNeighbourLanguage, forKey: Key.catchesNeighbourLanguage) }
    }

    /// Учиться ли на правках: следить пятнадцать секунд за вставленным текстом и, найдя
    /// исправление ошибки распознавания, предлагать запомнить пару.
    ///
    /// Спрашиваем, а не включаем молча, по двум причинам сразу. Приложение читает поле
    /// ввода через Accessibility — то есть видит и то, что человек пишет после нашего
    /// текста; и разбирается в увиденном GPT, значит поле уезжает наружу. Такое не делают
    /// без ведома владельца, даже когда добавление в словарь всё равно подтверждается им
    /// вручную.
    @Published public var learnsFromEdits: Bool {
        didSet { defaults.set(learnsFromEdits, forKey: Key.learnsFromEdits) }
    }

    /// Чем слушать речь.
    ///
    /// Идеальной модели среди трёх нет — замерено на своих же записях. Быстрая turbo на
    /// фразе «проверь вебхук в Постмане, пересобери вебпак» услышала «в пост, но не
    /// пересобери»: слепила имя сервиса с частицей отрицания и перевернула смысл. Полная
    /// large-v3 ту же запись разобрала верно, но она вдвое медленнее, а на чистой речи
    /// не отличается от turbo вовсе. Parakeet быстрее обеих вдесятеро и точнее их в
    /// падежах, но каждое латинское слово пишет кириллицей — и держится на GPT-чистке,
    /// которая возвращает названиям латиницу.
    @Published public var recognitionEngine: RecognitionEngine {
        didSet { defaults.set(recognitionEngine.rawValue, forKey: Key.recognitionEngine) }
    }

    /// Граница «короткой» диктовки в словах.
    @Published public var shortDictationWordLimit: Int {
        didSet { defaults.set(shortDictationWordLimit, forKey: Key.shortDictationWordLimit) }
    }

    /// Поля ввода в активном приложении нет — показать текст карточкой у нижнего левого угла
    /// вместо вставки вслепую. Выключено — всё как раньше: Cmd-V летит в любом случае.
    @Published public var cardsWhenNoField: Bool {
        didSet { defaults.set(cardsWhenNoField, forKey: Key.cardsWhenNoField) }
    }

    /// Сколько последних записей держим на диске для повторного распознавания.
    /// Звук — самое личное, что есть у диктовки, поэтому кольцо короткое и явное: 0 —
    /// не хранить вовсе, 3 — по умолчанию (см. `RecordingStore`).
    @Published public var keptRecordings: Int {
        didSet { defaults.set(keptRecordings, forKey: Key.keptRecordings) }
    }

    /// Кнопка записи: правый ⌘ (по умолчанию) или шорткат из KeyboardShortcuts.
    @Published public var dictationHotkeyMode: HotkeyMode {
        didSet { defaults.set(dictationHotkeyMode.rawValue, forKey: Key.dictationHotkeyMode) }
    }

    /// UID выбранного микрофона; nil — системный по умолчанию (nil стирает ключ).
    @Published public var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    /// Сколько диктовок начато за всё время. Считаем ровно ради одного — показать подсказку
    /// про наложение на третьей и больше никогда, поэтому счёт останавливается вместе с ней.
    ///
    /// Без `@Published`: на это никто не подписан, а лишний сигнал перерисовывал бы меню
    /// на каждом старте записи.
    public var dictationsStarted: Int {
        get { defaults.integer(forKey: Key.dictationsStarted) }
        set { defaults.set(newValue, forKey: Key.dictationsStarted) }
    }

    /// Подсказку «не ждите обработки, говорите дальше» уже показывали. Один раз за всю
    /// жизнь: второй раз она уже не новость, а помеха.
    public var parallelHintShown: Bool {
        get { defaults.bool(forKey: Key.parallelHintShown) }
        set { defaults.set(newValue, forKey: Key.parallelHintShown) }
    }

    public var gptConfig: GPTConfig {
        GPTConfig(mode: gptMode, model: gptModel, effort: gptEffort)
    }

    /// Конфигурация переводящего вызова: доступ общий, модель и усилие — свои.
    public var translateGPTConfig: GPTConfig {
        GPTConfig(mode: gptMode, model: translateModel, effort: translateEffort)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Key.language).flatMap(Language.init(rawValue:)) ?? .ru
        gptEnabled = defaults.object(forKey: Key.gptEnabled) as? Bool ?? true
        let mode = defaults.string(forKey: Key.gptMode).flatMap(GPTAuthMode.init(rawValue:)) ?? .codex
        gptMode = mode
        gptModel = defaults.string(forKey: Key.gptModel) ?? GPTConfig.defaultModel(for: mode)
        gptEffort = defaults.string(forKey: Key.gptEffort) ?? Self.defaultCleanupEffort
        translateToEnglish = defaults.bool(forKey: Key.translateToEnglish)
        // Дефолт перевода не зависит от режима доступа: terra есть у обоих бэкендов и на
        // переводе надёжнее быстрой модели, которой обычно хватает для одной лишь чистки.
        translateModel = defaults.string(forKey: Key.translateModel) ?? Self.defaultTranslateModel
        translateEffort = defaults.string(forKey: Key.translateEffort) ?? Self.defaultTranslateEffort
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        autoStopEnabled = defaults.object(forKey: Key.autoStopEnabled) as? Bool ?? false
        skipGPTForShort = defaults.object(forKey: Key.skipGPTForShort) as? Bool ?? true
        restoreUkrainianInserts = defaults.object(forKey: Key.restoreUkrainianInserts) as? Bool ?? true
        catchesNeighbourLanguage = defaults.object(forKey: Key.catchesNeighbourLanguage) as? Bool ?? false
        shortDictationWordLimit = defaults.object(forKey: Key.shortDictationWordLimit) as? Int ?? 8
        learnsFromEdits = defaults.object(forKey: Key.learnsFromEdits) as? Bool ?? true
        recognitionEngine = defaults.string(forKey: Key.recognitionEngine)
            .flatMap(RecognitionEngine.init(rawValue:)) ?? .fast
        cardsWhenNoField = defaults.object(forKey: Key.cardsWhenNoField) as? Bool ?? true
        keptRecordings = defaults.object(forKey: Key.keptRecordings) as? Int ?? 3
        dictationHotkeyMode = defaults.string(forKey: Key.dictationHotkeyMode)
            .flatMap(HotkeyMode.init(rawValue:)) ?? .rightCommand
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
    }
}
