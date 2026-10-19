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

    /// Усилие рассуждения на переводе. Выше, чем на чистке: тот же вызов и чистит,
    /// и переводит, и ошибка перевода стоит дороже пропущенной запятой.
    ///
    /// Было `high` — из того же соображения, без замера. С переходом на `gpt-6-sol` замер
    /// это пересмотрел (2026-10-18): на `high` она переводила длинную диктовку 7–12 с, вдвое
    /// дольше прежней модели, а на `medium` — 5–7 с, при переводе не хуже. Прежняя модель
    /// на `high` в том же тексте вписала «first client» там, где сказано просто «по клиенту»;
    /// sol на обоих усилиях — нет.
    public static let defaultTranslateEffort = "medium"

    private enum Key {
        static let language = "language"
        static let gptEnabled = "gptEnabled"
        static let gptMode = "gptMode"
        static let inputDeviceUID = "inputDeviceUID"
        static let translateToEnglish = "translateToEnglish"
        static let translationTarget = "translationTarget"
        static let soundsEnabled = "soundsEnabled"
        static let autoStopEnabled = "autoStopEnabled"
        static let dictationHotkeyMode = "dictationHotkeyMode"
        static let languages = "languages"
        /// Прежний один язык и прежняя галочка «мешаю русский и українську». Только читаются —
        /// при первом запуске версии с набором языков из них собирается набор.
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

    /// На каких языках человек диктует. Никогда не пуст: снимать флажки — через
    /// `set(_:enabled:)`, который последний снять не даёт.
    @Published public private(set) var languages: Set<Language> {
        didSet { defaults.set(Language.ordered.filter(languages.contains).map(\.rawValue), forKey: Key.languages) }
    }

    /// Отметить или снять язык. Последний снять нельзя: диктовать совсем без языка не на чем,
    /// и флажок просто не снимается.
    public func set(_ language: Language, enabled: Bool) {
        var next = languages
        if enabled { next.insert(language) } else { next.remove(language) }
        guard !next.isEmpty, next != languages else { return }
        languages = next
    }

    /// Один язык — там, где текста ещё нет и выбрать по нему нельзя: прогрев модели, перевод
    /// чужого текста с карточки. Присвоение оставляет отмеченным только его — так работает
    /// переключение языка хоткеем.
    public var language: Language {
        get { Language.ordered.first(where: languages.contains) ?? .ru }
        set { languages = [newValue] }
    }

    @Published public var gptEnabled: Bool {
        didSet { defaults.set(gptEnabled, forKey: Key.gptEnabled) }
    }

    @Published public var gptMode: GPTAuthMode {
        didSet { defaults.set(gptMode.rawValue, forKey: Key.gptMode) }
    }

    /// Диктовка вставляется переводом (GPT-слой переводит вместо простой чистки).
    ///
    /// Имя ключа осталось от тех времён, когда цель была одна — английский. Переименовать
    /// его значило бы сбросить настройку у всех, кто уже обновился; цена косметическая,
    /// а неудобство настоящее.
    @Published public var translateToEnglish: Bool {
        didSet { defaults.set(translateToEnglish, forKey: Key.translateToEnglish) }
    }

    /// На какой язык переводит правый ⌥.
    @Published public var translationTarget: TranslationTarget {
        didSet { defaults.set(translationTarget.rawValue, forKey: Key.translationTarget) }
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

    /// Человек мешает русский с украинским в одной диктовке — то есть отмечены оба.
    ///
    /// Правит один слой — чистку, — но с двух сторон сразу, потому что беда у смешанной
    /// речи двусторонняя. Украинское слово, услышанное верно, чистка иначе переписывает
    /// по-русски («ще раз» → «ещё раз»); украинское слово, записанное распознаванием на слух
    /// по-русски («требо» вместо «треба»), иначе таким и остаётся.
    ///
    /// Раньше это была отдельная галочка рядом с выбором одного языка. С набором языков
    /// она стала тем же самым намерением, сказанным вторым флажком, и отдельно не живёт.
    public var mixesUkrainian: Bool { languages.contains(.ru) && languages.contains(.uk) }

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
        var config = GPTConfig(mode: gptMode, model: nil, effort: Self.defaultCleanupEffort)
        config.serviceTier = Self.serviceTier(for: gptMode)
        return config
    }

    /// Конфигурация переводящего вызова: модель та же, усилие выше — переводит тот же вызов,
    /// и ошибка перевода стоит дороже пропущенной запятой.
    public var translateGPTConfig: GPTConfig {
        var config = GPTConfig(mode: gptMode, model: nil, effort: Self.defaultTranslateEffort)
        config.serviceTier = Self.serviceTier(for: gptMode)
        return config
    }

    /// Режим Fast — на пути через вход ChatGPT, и только там.
    ///
    /// Чистка ждала не генерации, а первого слова: по 19 живым диктовкам 0.5.0 медиана
    /// 4,6 с, из них 93% — молчание сервера до первого слова. Замер 2026-10-19 вперемешку,
    /// с паузами как между диктовками: `gpt-6-sol` 5,2 с, с Fast — 1,5 с (худший 1,9 с)
    /// при той же модели и том же качестве. Цена — лимит ChatGPT расходуется быстрее
    /// (по данным официального клиента Codex — примерно в 2,5 раза), и владелец её выбрал.
    /// Прогрев промпта перед запросом не помог вовсе — с ним вышло 6,7 с.
    ///
    /// С API-ключом не включаем: там Fast вдвое дороже деньгами, а без него и так быстро,
    /// и платить за это без спроса чужим ключом незачем.
    static func serviceTier(for mode: GPTAuthMode) -> String? {
        mode == .codex ? "priority" : nil
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        languages = Self.storedLanguages(in: defaults)
        gptEnabled = defaults.object(forKey: Key.gptEnabled) as? Bool ?? true
        gptMode = defaults.string(forKey: Key.gptMode).flatMap(GPTAuthMode.init(rawValue:)) ?? .codex
        translateToEnglish = defaults.bool(forKey: Key.translateToEnglish)
        // Английский по умолчанию: у тех, кто обновится, перевод останется ровно тем же.
        translationTarget = defaults.string(forKey: Key.translationTarget)
            .flatMap(TranslationTarget.init(rawValue:)) ?? .en
        pillStyle = defaults.string(forKey: Key.pillStyle).flatMap(PillStyle.init(rawValue:)) ?? .wave
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        autoStopEnabled = defaults.object(forKey: Key.autoStopEnabled) as? Bool ?? false
        learnsFromEdits = defaults.object(forKey: Key.learnsFromEdits) as? Bool ?? true
        cardsWhenNoField = defaults.object(forKey: Key.cardsWhenNoField) as? Bool ?? true
        keptRecordings = defaults.object(forKey: Key.keptRecordings) as? Int ?? 3
        dictationHotkeyMode = defaults.string(forKey: Key.dictationHotkeyMode)
            .flatMap(HotkeyMode.init(rawValue:)) ?? .rightCommand
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
    }

    /// Набор языков с диска, а без него — собранный из прежних настроек.
    ///
    /// Прежде был один язык и галочка «мешаю русский и українську», по умолчанию включённая.
    /// Русский с галочкой — это ровно «оба», без неё — один русский. Украинский — всегда
    /// один украинский: галочка на украинскую чистку не влияла вовсе (её читала только
    /// русская ветка промпта), и стоять она там могла лишь потому, что стояла у всех.
    /// Превратить её в «оба» значило бы сделать основным русский — и короткое «Дякую,
    /// гаразд» чистилось бы по-русски. Так у того, кто обновился, чистка ведёт себя как раньше.
    static func storedLanguages(in defaults: UserDefaults) -> Set<Language> {
        if let stored = defaults.array(forKey: Key.languages) as? [String] {
            let parsed = Set(stored.compactMap(Language.init(rawValue:)))
            if !parsed.isEmpty { return parsed }
        }
        let single = defaults.string(forKey: Key.language).flatMap(Language.init(rawValue:)) ?? .ru
        // Дефолт `true`: прежняя галочка про украинские вставки тоже стояла по умолчанию,
        // а её самая старая половина жила под другим ключом.
        let mixes = defaults.object(forKey: Key.mixesUkrainian) as? Bool
            ?? defaults.object(forKey: Key.legacyRestoreUkrainian) as? Bool
            ?? true
        switch single {
        case .en: return [.en]
        case .ru: return mixes ? [.ru, .uk] : [.ru]
        case .uk: return [.uk]
        }
    }
}
