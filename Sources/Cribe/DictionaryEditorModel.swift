import Combine
import Foundation
import SwiftUI
import CribeCore

/// Состояние редактора словаря: карточки терминов, автосохранение, отмена удаления
/// и заготовка нового термина. Вся логика, которую есть смысл проверить, — статические
/// функции ниже: они чистые и живут без SwiftUI.
@MainActor
final class DictionaryEditorModel: ObservableObject {

    /// Карточка термина. `note` — короткая реплика самой карточки («объединено»,
    /// «сгенерировано офлайн»), она живёт только до следующего действия.
    struct Term: Identifiable, Equatable {
        let id: UUID
        var canonical: String
        var variants: [String]
        var stem: Bool
        var isGenerating = false
        var note: String?

        init(_ entry: DictionaryEntry) {
            id = entry.id
            canonical = entry.canonical
            variants = entry.variants
            stem = entry.stem
        }

        init(canonical: String, variants: [String], stem: Bool = true) {
            id = UUID()
            self.canonical = canonical
            self.variants = variants
            self.stem = stem
        }

        var entry: DictionaryEntry {
            DictionaryEntry(id: id, canonical: canonical, variants: variants, stem: stem)
        }
    }

    /// Заготовка термина: вариант уже известен (слово из диктовки или подсказка),
    /// а каноническую форму пользователь дописывает сам.
    struct Draft: Equatable {
        var canonical: String
        var variants: [String]
        /// Слово-подсказка, которое надо погасить в списке подсказок при создании.
        var suggestion: String?
    }

    struct Removed: Equatable {
        let term: Term
        let index: Int
    }

    enum SaveState: Equatable {
        case idle
        case editing
        case saved
        case failed(String)
    }

    /// Пауза перед записью на диск: пользователь печатает вариант посимвольно,
    /// и писать файл на каждую букву незачем.
    static let saveDelay = Duration.milliseconds(400)
    /// Сколько держим предложение отменить удаление.
    static let undoDelay = Duration.seconds(5)

    @Published var terms: [Term] = []
    @Published var search = ""
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var removed: Removed?
    @Published var draft: Draft?
    /// Развёрнута ли панель «из последней диктовки».
    @Published var showsDictation = false

    let dictionary: UserDictionary
    let settings: AppSettings
    let suggester: TermSuggester

    private let debounce = Debounce(delay: DictionaryEditorModel.saveDelay)
    private var undoTask: Task<Void, Never>?
    /// Порядок правок этой сессии, свежие первыми: в файл термины ложатся в нём,
    /// и следующее открытие редактора показывает недавнее сверху.
    private var touched: [UUID] = []
    /// Что мы сами записали последним — чтобы не перечитать собственную запись.
    private var lastWritten: [DictionaryEntry] = []

    init(dictionary: UserDictionary, settings: AppSettings, suggester: TermSuggester) {
        self.dictionary = dictionary
        self.settings = settings
        self.suggester = suggester
        reload()
    }

    // MARK: - Загрузка и сохранение

    /// Перечитывает словарь с диска. Правки, которые ещё не легли в файл, при этом
    /// пропали бы, поэтому незаписанное сначала дописываем.
    func reload() {
        if debounce.isPending { debounce.flush() }
        let entries = dictionary.entries
        guard entries != lastWritten || terms.isEmpty else { return }
        terms = entries.map(Term.init)
        lastWritten = entries
        touched = []
    }

    /// Любая правка карточки: показываем «печатаю» и заводим таймер записи.
    func edited(_ id: UUID? = nil) {
        if let id { touch(id) }
        saveState = .editing
        debounce.schedule { [weak self] in self?.save() }
    }

    /// Немедленная запись — на закрытии окна: таймер отменять некому.
    func flush() {
        debounce.flush()
    }

    private func touch(_ id: UUID) {
        touched.removeAll { $0 == id }
        touched.insert(id, at: 0)
    }

    private func save() {
        let entries = Self.entries(from: terms, touched: touched)
        dictionary.replace(entries: entries)
        lastWritten = entries
        // Замены в памяти применяются в любом случае — молчать о несохранённом файле нельзя.
        saveState = dictionary.lastSaveError.map { .failed($0.localizedDescription) } ?? .saved
        suggester.refresh(entries: entries)
    }

    // MARK: - Термины

    /// Новый термин: либо своя карточка, либо слияние с уже существующей.
    /// Возвращает id карточки — вызывающий код по нему запускает генерацию.
    @discardableResult
    func add(canonical: String, variants: [String] = [], stem: Bool = true) -> UUID? {
        let term = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        let result = Self.merging(terms, canonical: term, variants: variants, stem: stem)
        terms = result.terms
        edited(result.id)
        return result.merged ? nil : result.id
    }

    func remove(_ id: UUID) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        removed = Removed(term: terms[index], index: index)
        terms.remove(at: index)
        touched.removeAll { $0 == id }
        edited()

        // Предложение отменить живёт секунды: дальше оно становится мусором на экране.
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoDelay)
            guard !Task.isCancelled else { return }
            self?.removed = nil
        }
    }

    func undoRemove() {
        guard let removed else { return }
        undoTask?.cancel()
        terms.insert(removed.term, at: min(removed.index, terms.count))
        self.removed = nil
        edited(removed.term.id)
    }

    func addVariant(_ variant: String, to id: UUID) {
        let value = variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, let index = terms.firstIndex(where: { $0.id == id }) else { return }
        guard !terms[index].variants.contains(value) else { return }
        terms[index].variants.append(value)
        terms[index].note = nil
        edited(id)
    }

    func removeVariant(_ variant: String, from id: UUID) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].variants.removeAll { $0 == variant }
        edited(id)
    }

    // MARK: - Генерация вариантов

    /// Спрашиваем модель, а если её нет или она не ответила — берём транслитерацию.
    /// Карточка на это время крутит спиннер, но правки не блокирует.
    func generate(for id: UUID) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        let canonical = terms[index].canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty, !terms[index].isGenerating else { return }

        terms[index].isGenerating = true
        terms[index].note = nil
        let useGPT = settings.gptEnabled
        let config = settings.gptConfig

        Task { [weak self] in
            var generated: [String] = []
            var offline = true
            if useGPT,
               let remote = try? await VariantGenerator.variants(for: canonical, config: config),
               !remote.isEmpty {
                generated = remote
                offline = false
            }
            if generated.isEmpty {
                generated = VariantGenerator.localVariants(for: canonical)
            }
            self?.applyGenerated(generated, offline: offline, to: id)
        }
    }

    private func applyGenerated(_ generated: [String], offline: Bool, to id: UUID) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].isGenerating = false
        let added = Self.appending(generated, to: terms[index].variants)
        if added == terms[index].variants {
            terms[index].note = generated.isEmpty
                ? "варианты не придумались — впишите вручную"
                : "новых вариантов нет"
            return
        }
        terms[index].variants = added
        terms[index].note = offline ? "по правилам, без модели" : nil
        edited(id)
    }

    // MARK: - Подсказки

    func acceptSuggestion(_ candidate: TermCandidate) {
        // Латинское слово уже похоже на канонический термин — предлагаем его как есть;
        // кириллическое, наоборот, годится только вариантом.
        let isLatin = candidate.token.allSatisfy(\.isASCII)
        draft = Draft(
            canonical: isLatin ? candidate.token : "",
            variants: isLatin ? [] : [candidate.token],
            suggestion: candidate.token
        )
    }

    func ignoreSuggestion(_ candidate: TermCandidate) {
        suggester.ignore(candidate.token, entries: terms.map(\.entry))
    }

    /// Слово из последней диктовки: оно и есть готовый вариант, осталась каноническая форма.
    func draftFromDictation(word: String) {
        draft = Draft(canonical: "", variants: [word.lowercased()], suggestion: nil)
    }

    /// Заготовка стала термином: карточка (или слияние) плюс генерация недостающего.
    func commitDraft() {
        guard let draft else { return }
        let created = add(canonical: draft.canonical, variants: draft.variants)
        if let suggestion = draft.suggestion {
            suggester.accept(suggestion, entries: terms.map(\.entry))
        }
        // Генерируем только новой карточке: у существующей варианты уже собраны.
        if let created { generate(for: created) }
        self.draft = nil
    }

    // MARK: - Чистая логика

    /// Порядок записи: правки этой сессии сверху, свежие первыми, остальное — как было.
    /// Так «недавно добавленное» оказывается наверху при следующем открытии окна,
    /// а карточки не прыгают под курсором прямо во время правки.
    static func entries(from terms: [Term], touched: [UUID]) -> [DictionaryEntry] {
        let valid = terms.filter { !$0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let recent = touched.compactMap { id in valid.first { $0.id == id } }
        let rest = valid.filter { term in !touched.contains(term.id) }
        return (recent + rest).map { term in
            DictionaryEntry(
                id: term.id,
                canonical: term.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
                variants: term.variants,
                stem: term.stem
            )
        }
    }

    /// Термин с такой же канонической формой уже есть — варианты вливаются в него,
    /// а не заводят вторую карточку: два правила на один термин ведут себя непредсказуемо.
    static func merging(
        _ terms: [Term],
        canonical: String,
        variants: [String],
        stem: Bool
    ) -> (terms: [Term], id: UUID, merged: Bool) {
        var terms = terms
        let normalized = VariantGenerator.normalized(variants, canonical: canonical)

        if let index = terms.firstIndex(where: { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame }) {
            let before = terms[index].variants
            terms[index].variants = appending(normalized, to: before)
            terms[index].note = terms[index].variants == before
                ? "такой термин уже есть"
                : "варианты добавлены к существующему термину"
            return (terms, terms[index].id, true)
        }

        let term = Term(canonical: canonical, variants: normalized, stem: stem)
        terms.insert(term, at: 0)
        return (terms, term.id, false)
    }

    /// Дописывает варианты, не трогая порядок уже имеющихся и не заводя дублей.
    static func appending(_ variants: [String], to existing: [String]) -> [String] {
        var result = existing
        var seen = Set(existing.map { $0.lowercased() })
        for variant in variants {
            let value = variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    /// Отбор по строке поиска: и по термину, и по вариантам — искать пользователь будет
    /// и то, что слышит, и то, что пишет.
    static func filtered(_ terms: [Term], search: String) -> [Term] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return terms }
        return terms.filter { term in
            term.canonical.lowercased().contains(query)
                || term.variants.contains { $0.contains(query) }
        }
    }

    /// Слова последней диктовки для панели «добавить из диктовки»: без пунктуации,
    /// без повторов и без того, что словарь уже знает. Короче трёх букв («на», «и»)
    /// терминов не бывает — такие чипсы были бы только шумом под курсором.
    static func words(in text: String, known: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(word).lowercased()
            guard value.count >= 3, !known.contains(value), seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }
}

/// Отложенный вызов с перезапуском: каждая новая правка сдвигает запись на диск.
/// Живёт отдельным типом ради теста — таймер внутри вью проверить нечем.
@MainActor
final class Debounce {
    private let delay: Duration
    private var task: Task<Void, Never>?
    private var pending: (@MainActor () -> Void)?

    var isPending: Bool { pending != nil }

    init(delay: Duration) {
        self.delay = delay
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        pending = action
        task = Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Выполняет отложенное прямо сейчас; без отложенного не делает ничего.
    func flush() {
        task?.cancel()
        task = nil
        let action = pending
        pending = nil
        action?()
    }
}
