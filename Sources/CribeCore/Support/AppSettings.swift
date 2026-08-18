import Combine
import Foundation

/// Что показывает капсула, пока идёт запись.
public enum PillStyle: String, Codable, CaseIterable, Sendable {
    /// Столбики уровня. Ничего не стоит: уровень и так меряется для автостопа.
    case wave
    /// Бегущая строка распознанного. Красивее и честнее (видно, что услышано), но стоит
    /// прохода распознавания примерно раз в секунду — поэтому спрашиваем, а не включаем всем.
    case words
}

/// Чем запускается диктовка: «голым» правым ⌘ или своим шорткатом.
public enum HotkeyMode: String, Codable, CaseIterable, Sendable {
    case rightCommand
    case custom
}

/// Настройки приложения поверх UserDefaults. Каждое поле пишется на диск при изменении,
/// UI подписан через `@Published`.
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    /// Усилие рассуждения на чистке.
    ///
    /// Было `medium` — из соображения «чистка живой речи не разметка текста». Замер этого
    /// не подтвердил: 210 прогонов по 17 проверкам на 10 своих записях дали у `low` те же
    /// 51/51, что и у `medium`, при медиане 2,48 с против 2,82 с. Платить третью секунды
    /// и лишнюю квоту за неразличимое качество незачем.
    public static let defaultCleanupEffort = "low"

    /// Усилие рассуждения на переводе. Выше: тот же вызов и чистит, и переводит,
    /// и ошибка перевода стоит дороже пропущенной запятой.
    public static let defaultTranslateEffort = "high"

    private enum Key {
        static let language = "language"
        static let gptEnabled = "gptEnabled"
        static let gptMode = "gptMode"
        static let inputDeviceUID = "inputDeviceUID"
        static let translateToEnglish = "translateToEnglish"
        static let soundsEnabled = "soundsEnabled"
        static let autoStopEnabled = "autoStopEnabled"
        static let dictationHotkeyMode = "dictationHotkeyMode"
        static let mixesUkrainian = "mixesUkrainian"
        static let pillStyle = "pillStyle"
        /// Прежний ключ той же галочки: с него читается значение при первом запуске новой
        /// версии, иначе выбор человека молча сбросился бы на дефолт.
        static let legacyRestoreUkrainian = "restoreUkrainianInserts"
        static let learnsFromEdits = "learnsFromEdits"
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

    /// Диктовка вставляется переводом на английский (GPT-слой переводит вместо простой чистки).
    @Published public var translateToEnglish: Bool {
        didSet { defaults.set(translateToEnglish, forKey: Key.translateToEnglish) }
    }

    /// Волна или бегущая строка слов в капсуле записи.
    ///
    /// По умолчанию волна. Слова требуют повторных проходов распознавания по хвосту записи
    /// (см. `DictationController.livePreview`) — на ноутбуке без розетки это заметно, и
    /// платить за украшение без спроса нельзя.
    @Published public var pillStyle: PillStyle {
        didSet { defaults.set(pillStyle.rawValue, forKey: Key.pillStyle) }
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

    /// Человек мешает русский с украинским в одной диктовке.
    ///
    /// Галочка правит один слой — чистку, — но с двух сторон сразу, потому что беда у
    /// смешанной речи двусторонняя. Украинское слово, услышанное верно, чистка иначе
    /// переписывает по-русски («ще раз» → «ещё раз»); украинское слово, записанное
    /// распознаванием на слух по-русски («требо» вместо «треба»), иначе таким и остаётся.
    /// Обе половины включаются одним намерением человека, поэтому и тумблер один.
    ///
    /// Выключено — диктовка считается одноязычной, и случайное украинское слово в тексте
    /// человеку не нужно.
    @Published public var mixesUkrainian: Bool {
        didSet { defaults.set(mixesUkrainian, forKey: Key.mixesUkrainian) }
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

    /// Модель и усилие человек не выбирает: выбор был, и замер его закрыл. 210 прогонов
    /// по 17 проверкам на 10 живых записях дали победителя без спорных мест — terra на `low`
    /// оказалась и самой быстрой (медиана 2,5 с), и не хуже всех остальных по качеству,
    /// а «экономная» luna была одновременно медленнее (3,9 с) и хуже. Держать в настройках
    /// выбор, у которого один правильный ответ, — значит предлагать человеку ошибиться.
    public var gptConfig: GPTConfig {
        GPTConfig(mode: gptMode, model: nil, effort: Self.defaultCleanupEffort)
    }

    /// Конфигурация переводящего вызова: модель та же, усилие выше — переводит тот же вызов,
    /// и ошибка перевода стоит дороже пропущенной запятой.
    public var translateGPTConfig: GPTConfig {
        GPTConfig(mode: gptMode, model: nil, effort: Self.defaultTranslateEffort)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Key.language).flatMap(Language.init(rawValue:)) ?? .ru
        gptEnabled = defaults.object(forKey: Key.gptEnabled) as? Bool ?? true
        gptMode = defaults.string(forKey: Key.gptMode).flatMap(GPTAuthMode.init(rawValue:)) ?? .codex
        translateToEnglish = defaults.bool(forKey: Key.translateToEnglish)
        pillStyle = defaults.string(forKey: Key.pillStyle).flatMap(PillStyle.init(rawValue:)) ?? .wave
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        autoStopEnabled = defaults.object(forKey: Key.autoStopEnabled) as? Bool ?? false
        // Дефолт `true`, и он же достаётся тем, кто обновился: прежняя галочка про украинские
        // вставки тоже стояла по умолчанию, а вторая её половина раньше жила отдельно.
        mixesUkrainian = defaults.object(forKey: Key.mixesUkrainian) as? Bool
            ?? defaults.object(forKey: Key.legacyRestoreUkrainian) as? Bool
            ?? true
        learnsFromEdits = defaults.object(forKey: Key.learnsFromEdits) as? Bool ?? true
        cardsWhenNoField = defaults.object(forKey: Key.cardsWhenNoField) as? Bool ?? true
        keptRecordings = defaults.object(forKey: Key.keptRecordings) as? Int ?? 3
        dictationHotkeyMode = defaults.string(forKey: Key.dictationHotkeyMode)
            .flatMap(HotkeyMode.init(rawValue:)) ?? .rightCommand
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
    }
}
