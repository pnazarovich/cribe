import AppKit
import SwiftUI
import CribeCore

/// История диктовок: текст целиком, правка и повторное распознавание.
///
/// Окно существует ради двух вещей, которых нигде больше нет. Первая: если распознавание
/// потеряло речь, запись всё ещё лежит на диске, и её можно разобрать заново — другим
/// путём, а не тем же самым. Вторая: карточка держит четыре строки, а диктовка бывает
/// длинной — увидеть её целиком, поправить и что-то с ней сделать можно только здесь.
/// Поэтому кнопка «посмотреть целиком» на карточке ведёт сюда, а не заводит третье окно.
struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    /// Общее состояние приложения: заявка «раскрой эту диктовку» из карточки, дорога
    /// в редактор словаря и переводчик — всё это живёт там же, где меню в строке состояния.
    @ObservedObject var core: AppCore

    @StateObject private var model = HistoryModel()

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 440)
            .glassWindow()
            .onAppear { model.sync(history: history) }
            // Окно закрывают, не дожидаясь таймера, — недописанную правку дописываем сами.
            .onDisappear { model.flush() }
    }

    @ViewBuilder
    private var content: some View {
        if #available(macOS 26.0, *) {
            list.safeAreaBar(edge: .top) { toolbar }
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                list
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Text("История диктовок")
                .font(.headline)
            Spacer()
            Text(model.storageNote(keeping: settings.keptRecordings))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if history.items.isEmpty {
                        Text("Диктовок пока не было.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(history.items) { item in
                            HistoryRow(
                                item: item,
                                model: model,
                                controller: controller,
                                history: history,
                                translator: core.translator,
                                keptRecordings: settings.keptRecordings,
                                onDictionary: { openDictionary(with: item.text) }
                            )
                            .id(item.id)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { reveal(core.historyFocus, proxy: proxy) }
            .onChange(of: core.historyFocus) { _, text in reveal(text, proxy: proxy) }
        }
    }

    // MARK: - Вход с карточки

    /// Карточка прислала свой текст — раскрываем ту самую строку и подводим к ней окно.
    ///
    /// Ищем по тексту, а не по id: карточка появляется раньше, чем конвейер запишет строку
    /// в историю, так что id ей взять неоткуда (см. `AppCore.historyFocus`). Совпадение
    /// однозначное — в историю ложится ровно тот текст, что уехал на карточку, — а самая
    /// свежая диктовка идёт в списке первой.
    private func reveal(_ text: String?, proxy: ScrollViewProxy) {
        guard let text else { return }
        // Заявка разовая: гасим её сразу, иначе следующее открытие окна повторило бы
        // раскрытие поверх того, что человек к тому моменту выбрал сам.
        core.historyFocus = nil
        // Строки может и не быть: карточка висит, пока её не уберут, и за двадцать
        // следующих диктовок эту успевает вытеснить. Тогда окно просто открывается.
        guard let item = HistoryModel.row(matching: text, in: history.items) else { return }
        model.expand(item)
        withAnimation { proxy.scrollTo(item.id, anchor: .top) }
    }

    /// Слова этой диктовки — в редактор словаря, той же панелью «Из последней диктовки»,
    /// которую зовёт меню. Второй двери к словарю в приложении нет и заводить её незачем.
    private func openDictionary(with text: String) {
        core.dictionaryDictation = text
        core.dictionaryFocus = .lastDictation
        WindowPresenter.shared.present(WindowID.dictionary) {
            openWindow(id: WindowID.dictionary)
        }
    }
}

/// Одна диктовка: текст, отметки о записи и действия над ней.
///
/// Свёрнутая строка — то, что было всегда: текст и повторный разбор. Раскрытая заменяет
/// текст полем ввода и добавляет остальное, что с диктовкой вообще можно сделать.
private struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryModel
    let controller: DictationController
    let history: HistoryStore
    let translator: CardTranslator
    /// Сколько записей кольцо держит на диске: об этом говорим, когда записи уже нет.
    let keptRecordings: Int
    let onDictionary: () -> Void

    private var isExpanded: Bool { model.expanded == item.id }

    /// Что сейчас на строке — оно же копируется и переводится.
    private var shownText: String { isExpanded ? model.draft : item.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            text
            if let warning { caption(warning, warning: true) }
            if isExpanded {
                caption(recordingNote, warning: false)
                if let translation = model.translation { translationBlock(translation) }
                if let failure = model.translateFailure { caption(failure, warning: true) }
            }
            actions
            if model.busyItem == item.id, let note = model.note {
                caption(note, warning: model.noteIsError)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
            Text("·")
            Text(item.language.displayName)
            if let seconds = item.seconds {
                Text("·")
                Text(HistoryModel.duration(seconds))
            }
            // Ровно потолок — значит, запись была длиннее и легла обрезанной. Молчать об этом
            // нельзя: повтор разберёт только сохранённую часть.
            if item.audio != nil, (item.seconds ?? 0) >= RecordingStore.maxSeconds {
                Text("· запись обрезана до 5 мин")
            }
            Spacer()
            if item.audio == nil {
                Text("записи нет")
                    .foregroundStyle(.tertiary)
            }
            expandToggle
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Вход в раскрытую строку и выход из неё. Значок, а не слово: строк в списке двадцать,
    /// и слово в каждой шапке весило бы больше самой диктовки.
    private var expandToggle: some View {
        Button {
            isExpanded ? model.collapse() : model.expand(item)
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Свернуть" : "Посмотреть текст полностью — его можно поправить")
    }

    /// Раскрытая строка показывает текст полем ввода: он и есть «текст целиком», и правится
    /// прямо здесь. Свёрнутая — как и была.
    @ViewBuilder
    private var text: some View {
        if isExpanded {
            TextEditor(text: $model.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 180)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .onChange(of: model.draft) { _, _ in model.edited(in: history) }
        } else if item.text.isEmpty {
            Text("Распознать не удалось — но запись сохранилась.")
                .foregroundStyle(.secondary)
                .italic()
        } else {
            Text(item.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Речи на выходе мало для такой записи — то самое молчаливое «половина пропала».
    private var warning: String? {
        guard !item.text.isEmpty,
              TranscriptQuality.looksTruncated(text: item.text, seconds: item.seconds)
        else { return nil }
        return item.audio == nil
            ? "Текста мало для такой длинной записи — похоже, часть речи не распозналась."
            : "Текста мало для такой длинной записи — попробуйте распознать заново."
    }

    /// Связь строки с записью. Кольцо коротко, и разбирать заново бывает уже нечего —
    /// сказать об этом надо прямо, а не молчаливым отсутствием кнопки.
    private var recordingNote: String {
        guard item.audio != nil else {
            guard keptRecordings > 0 else {
                return "Записи не хранятся — так выбрано в настройках. Текст можно править и копировать."
            }
            return """
                Записи уже нет: на диске живут только самые свежие — сейчас \(keptRecordings). \
                Текст можно править и копировать, а распознавать заново нечего.
                """
        }
        let length = item.seconds.map { " (\(HistoryModel.duration($0)))" } ?? ""
        return "Запись\(length) ещё на диске — её можно распознать заново."
    }

    /// Перевод не подменяет собой оригинал: правка уезжает в историю, и подменённый текст
    /// стёр бы там саму диктовку. Поэтому он лежит рядом — целиком и с кнопкой.
    private func translationBlock(_ translation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Перевод на английский")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(translation)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Скопировать перевод") { HistoryModel.copy(translation) }
                .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Плоская заливка, не второе стекло: строка сама уже стеклянная плашка.
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Кнопки переносом, а не в одну строку: на раскрытой диктовке их пятеро, и в узком
    /// окне ряд иначе сплющивал бы подписи.
    private var actions: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            if !shownText.isEmpty {
                Button("Скопировать") { HistoryModel.copy(shownText) }
            }

            if isExpanded {
                Button("Перевести на английский") {
                    model.translate(shownText, using: translator)
                }
                .disabled(!translator.isAvailable() || model.isTranslating || shownText.isEmpty)
                .help(
                    translator.isAvailable()
                        ? "Перевод ляжет рядом с текстом, а не вместо него."
                        : "Перевод делает GPT — включите AI-чистку в меню."
                )

                Button("Слова в словарь…") { onDictionary() }
                    .disabled(shownText.isEmpty)
                    .help("Открыть словарь на этой диктовке: слова добавляются одним щелчком.")
            }

            if item.audio != nil {
                Button("Распознать заново") {
                    model.retranscribe(item, mode: .samePlainPass, controller: controller)
                }
                .disabled(model.isBusy)

                Button("…на большой модели") {
                    model.retranscribe(item, mode: .largeModel, controller: controller)
                }
                .disabled(model.isBusy)
                .help(
                    "large-v3: идёт в разы дольше и на русском часто хуже — украинизирует "
                        + "слова («провєріть пріложення»). Занимает 2,9 ГБ на диске."
                )
            }

            if model.busyItem == item.id || (isExpanded && model.isTranslating) {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
    }

    private func caption(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Состояние окна: какая строка раскрыта, что в ней написано прямо сейчас, какая
/// пересчитывается и что ей сказать.
///
/// Раскрытая строка ровно одна, поэтому черновик правки и перевод живут здесь, а не в
/// самих строках: так они переживают перерисовку списка (а он перерисовывается на каждой
/// записи в историю) и так их видно тесту.
/// Подтверждение на скачивание large-v3 живёт здесь же — 2,9 ГБ молча не качаем.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var busyItem: UUID?
    @Published var note: String?
    @Published var noteIsError = false

    /// Раскрытая строка; nil — раскрытых нет.
    @Published private(set) var expanded: UUID?
    /// Текст раскрытой строки, каким его правят прямо сейчас.
    @Published var draft = ""
    /// Перевод раскрытой строки. Лежит рядом с текстом, а не вместо него.
    @Published private(set) var translation: String?
    @Published private(set) var isTranslating = false
    @Published private(set) var translateFailure: String?

    private let recordings = RecordingStore.shared
    private var bytes: Int64 = 0
    /// Правку пишем не на каждую букву — той же паузой, что и в редакторе словаря.
    private let debounce = Debounce(delay: DictionaryEditorModel.saveDelay)

    var isBusy: Bool { busyItem != nil }

    /// Кольцо записей короче истории — строки, чей звук уже вытеснен, не должны предлагать
    /// кнопку в никуда.
    func sync(history: HistoryStore) {
        history.forgetAudio { [recordings] name in recordings.url(named: name) != nil }
        bytes = recordings.bytesOnDisk()
    }

    func storageNote(keeping: Int) -> String {
        guard keeping > 0 else { return "Записи не хранятся" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "Записей на диске: \(size)"
    }

    // MARK: - Раскрытая строка

    /// Раскрывает строку: её текст становится черновиком, и правится дальше именно он.
    /// Прежняя раскрытая строка при этом дописывается — переключение не теряет правку.
    func expand(_ item: HistoryItem) {
        flush()
        expanded = item.id
        draft = item.text
        translation = nil
        translateFailure = nil
    }

    func collapse() {
        flush()
        expanded = nil
        draft = ""
        translation = nil
        translateFailure = nil
    }

    /// Правка черновика: на диск она уезжает сама, как и в редакторе словаря.
    func edited(in history: HistoryStore) {
        debounce.schedule { [weak self] in self?.save(to: history) }
    }

    /// Дописывает отложенное прямо сейчас — на сворачивании строки и на закрытии окна.
    func flush() {
        debounce.flush()
    }

    /// Кладёт черновик в историю.
    ///
    /// Пустой не кладём: пустой текст в истории означает «распознать не удалось» и держит
    /// строку живой ради записи — стереть диктовку начисто правкой было бы не тем, о чём
    /// просили. Совпавший тоже не кладём: запись в историю перерисовывает весь список.
    func save(to history: HistoryStore) {
        guard let expanded else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              history.items.first(where: { $0.id == expanded })?.text != text
        else { return }
        history.replace(id: expanded, text: text)
    }

    /// Перевод раскрытой строки тем же путём, что и у кнопки на карточке.
    func translate(_ text: String, using translator: CardTranslator) {
        guard translator.isAvailable(), !isTranslating else { return }
        isTranslating = true
        translation = nil
        translateFailure = nil
        Task {
            defer { isTranslating = false }
            do {
                translation = try await translator.translate(text)
            } catch {
                translateFailure = "Перевести не вышло: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Повторное распознавание

    func retranscribe(
        _ item: HistoryItem,
        mode: DictationController.RetranscribeMode,
        controller: DictationController
    ) {
        guard busyItem == nil else { return }
        if mode == .largeModel, !ModelStore.shared.isInstalled(variant: WhisperModel.large) {
            guard confirmLargeDownload() else { return }
        }

        busyItem = item.id
        noteIsError = false
        note = mode == .largeModel
            ? "Большая модель: это надолго — минуты, не секунды."
            : "Полный разбор целиком, без обрезки тишины и без словарного промпта…"

        Task {
            defer { busyItem = nil }
            do {
                let text = try await controller.retranscribe(item: item, mode: mode)
                // Раскрытая строка держит свой черновик: без этой строки он остался бы
                // прежним и следующей же правкой затёр бы то, что только что разобралось.
                if expanded == item.id { draft = text }
                note = "Готово — новый текст скопирован в буфер обмена."
            } catch {
                noteIsError = true
                note = "Не вышло: \(error.localizedDescription)"
            }
        }
    }

    /// 2,9 ГБ — не то, что качают за человека молча. Тому, кто диктует только по-русски,
    /// большая модель не нужна вовсе, и об этом говорим прямо здесь.
    private func confirmLargeDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Скачать большую модель (2,9 ГБ)?"
        alert.informativeText = """
            large-v3 нужна украинскому языку. На русском она идёт в разы дольше и часто хуже: \
            украинизирует слова — «провєріть пріложення», «всьо нормальна».
            """
        alert.addButton(withTitle: "Скачать")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Строка, с которой пришла карточка. Ищем по тексту: id у карточки нет — она
    /// появляется раньше, чем конвейер запишет строку (см. `AppCore.historyFocus`).
    /// В историю текст ложится подрезанным, поэтому подрезаем и пришедший.
    static func row(matching text: String, in items: [HistoryItem]) -> HistoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Свежая — первой: одну и ту же фразу диктуют не раз, и карточка на экране всегда
        // от последней такой диктовки.
        return items.first { $0.text == trimmed }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) c" : "\(total / 60) мин \(total % 60) c"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
