import SwiftUI
import CribeCore

/// Что показать в редакторе сразу после открытия из меню.
enum DictionaryFocus: Equatable {
    case lastDictation
    case corrections
}

/// Редактор словаря: карточка на термин, варианты — снимаемыми чипсами.
///
/// Кнопки «Сохранить» нет: правка уезжает в файл сама через `Debounce`. Это и есть
/// главное отличие от прежней таблицы — добавить термин теперь значит написать его
/// латиницей и подождать, пока варианты сгенерируются, а не выдумывать их руками.
struct DictionaryEditorView: View {
    @ObservedObject var learner: EditLearner

    /// Текст последней диктовки для панели «добавить из диктовки»; nil — диктовок не было.
    let lastDictation: String?
    /// Разовый сигнал «открыли из меню за этим»; редактор его сам и гасит.
    @Binding var focus: DictionaryFocus?

    @StateObject private var model: DictionaryEditorModel

    @State private var newTerm = ""
    /// Пустой словарь показывает не поле ввода, а пустое состояние; строка добавления
    /// появляется по кнопке из него — и дальше остаётся навсегда.
    @State private var addRequested = false
    @SwiftUI.FocusState private var isNewTermFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Якорь прокрутки к правкам: из меню в редактор приходят именно за ними.
    private static let correctionsAnchor = "corrections"

    /// Примеры для пустого словаря: те же программистские термины, что лежат в словаре
    /// по умолчанию. Варианты заданы руками — модель для них дёргать незачем.
    private static let examples: [(canonical: String, variants: [String])] = [
        ("deploy", ["деплой", "задеплой"]),
        ("commit", ["коммит", "закоммить"]),
        ("GitHub", ["гитхаб", "гит хаб"]),
        ("Docker", ["докер"])
    ]

    init(
        dictionary: UserDictionary,
        settings: AppSettings,
        learner: EditLearner,
        lastDictation: String?,
        focus: Binding<DictionaryFocus?>
    ) {
        self.learner = learner
        self.lastDictation = lastDictation
        _focus = focus
        _model = StateObject(
            wrappedValue: DictionaryEditorModel(
                dictionary: dictionary,
                settings: settings,
                learner: learner
            )
        )
    }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 440)
            .glassWindow()
            .overlay(alignment: .bottom) { undoBar }
            .animation(motion(.smooth(duration: 0.25)), value: model.removed)
            .animation(motion(.smooth(duration: 0.25)), value: model.draft)
            .animation(motion(.smooth(duration: 0.25)), value: model.showsDictation)
            .onAppear { model.reload() }
            // Окно закрывают, не дожидаясь таймера, — недописанное дописываем сами.
            .onDisappear { model.flush() }
    }

    /// На macOS 26 шапка отдаётся системе как бар безопасной области: под ней сама собой
    /// появляется scroll edge effect. Ниже — прежний волосяной разделитель.
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

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if showsAddRow { addRow }
                    if !learner.pending.isEmpty {
                        correctionsCard.id(Self.correctionsAnchor)
                    }
                    if model.showsDictation { dictationCard }
                    if model.draft != nil { draftCard }
                    terms
                }
                .padding(20)
                // Читаемая мера строки: на широком окне карточки не растягиваются.
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { apply(focus, proxy: proxy) }
            .onChange(of: focus) { _, focus in apply(focus, proxy: proxy) }
        }
    }

    /// «Уменьшение движения» — состояние меняется мгновенно, без пружин и раскрытий.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: - Шапка

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по терминам и вариантам", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Spacer(minLength: 8)
            saveMark
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Тихая отметка вместо кнопки: сохранение — не событие, о котором надо кричать,
    /// но провал записи молчать не имеет права.
    @ViewBuilder
    private var saveMark: some View {
        switch model.saveState {
        case .idle:
            EmptyView()
        case .editing:
            Text("…").font(.subheadline).foregroundStyle(.tertiary)
        case .saved:
            Label("Сохранено", systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        }
    }

    // MARK: - Добавление

    /// Пустой словарь — это первый экран нового пользователя, и поле ввода на нём лишнее:
    /// сначала объясняем, что словарь делает, потом даём его завести.
    private var showsAddRow: Bool { addRequested || !model.terms.isEmpty }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Новый термин (латиницей)", text: $newTerm)
                .textFieldStyle(.roundedBorder)
                .focused($isNewTermFocused)
                .onSubmit(addTerm)
            Button("Добавить", action: addTerm)
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                model.showsDictation.toggle()
            } label: {
                Label { Text("Из последней диктовки") } icon: { CrabGlyph(height: 13) }
            }
            .help("Взять слово из последней диктовки и сделать его вариантом")
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        newTerm = ""
        // Слияние возвращает nil: у существующей карточки варианты уже собраны.
        if let created = model.add(canonical: term) {
            model.generate(for: created)
        }
    }

    // MARK: - Карточки терминов

    private var terms: some View {
        let filtered = DictionaryEditorModel.filtered(model.terms, search: model.search)
        return Group {
            if filtered.isEmpty {
                if model.search.isEmpty {
                    emptyState
                } else {
                    Text("Ничего не найдено")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            } else {
                ForEach(filtered) { term in
                    TermCard(
                        term: term,
                        canonical: binding(term, \.canonical),
                        stem: binding(term, \.stem),
                        onEdit: { model.edited(term.id) },
                        onAddVariant: { model.addVariant($0, to: term.id) },
                        onRemoveVariant: { model.removeVariant($0, from: term.id) },
                        onGenerate: { model.generate(for: term.id) },
                        onDelete: { model.remove(term.id) }
                    )
                }
            }
        }
    }

    /// Карточка получает значение, а не биндинг, — правку сводим к поиску по id,
    /// как это было и в прежней таблице. Пропавшая карточка (успели удалить) отдаёт
    /// собственное значение: читать по индексу тут нельзя, список уже другой.
    private func binding<Value>(
        _ term: DictionaryEditorModel.Term,
        _ keyPath: WritableKeyPath<DictionaryEditorModel.Term, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.terms.first { $0.id == term.id }?[keyPath: keyPath] ?? term[keyPath: keyPath] },
            set: { value in
                guard let index = model.terms.firstIndex(where: { $0.id == term.id }) else { return }
                model.terms[index][keyPath: keyPath] = value
            }
        )
    }

    // MARK: - Пустое состояние

    /// Первый экран нового пользователя. Один приглушённый символ, одно предложение о том,
    /// что словарь делает с расшифровкой, одна основная кнопка — и готовые примеры,
    /// чтобы список не оставался по-настоящему пустым.
    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Словарь пуст", systemImage: "character.book.closed")
            } description: {
                Text("Словарь подменяет в расшифровке слова, которые распознались на слух: скажете «деплой» — в текст попадёт deploy.")
            } actions: {
                Button("Добавить слово") {
                    addRequested = true
                    isNewTermFocused = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            VStack(spacing: 6) {
                Text("Или возьмите готовое")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Self.examples, id: \.canonical) { example in
                        Button {
                            model.add(canonical: example.canonical, variants: example.variants)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.subheadline)
                                Text(example.canonical).font(.subheadline)
                            }
                            .chip()
                        }
                        .buttonStyle(.plain)
                        .help("Добавить «\(example.canonical)» и его варианты")
                    }
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Правки

    private var correctionsCard: some View {
        DictionaryCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Замеченные правки (\(learner.pending.count))", systemImage: "pencil.and.outline")
                    .font(.headline)
                Text("Вы поправили это в поле ввода. Повторится второй раз — уедет в словарь само.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(learner.pending) { learned in
                        CorrectionChip(
                            learned: learned,
                            onAccept: { model.acceptCorrection(learned) },
                            onIgnore: { model.ignoreCorrection(learned) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Из последней диктовки

    private var dictationCard: some View {
        DictionaryCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label { Text("Из последней диктовки") } icon: { CrabGlyph(height: 15) }
                        .font(.headline)
                    Spacer()
                    Button {
                        model.showsDictation = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if let text = lastDictation {
                    Text("Нажмите слово, которое распозналось неправильно.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(words(in: text), id: \.self) { word in
                            Button {
                                model.draftFromDictation(word: word)
                            } label: {
                                Text(word).font(.subheadline).chip()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("Диктовок ещё не было.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func words(in text: String) -> [String] {
        DictionaryEditorModel.words(in: text, known: DictionaryTokens.known(model.terms.map(\.entry)))
    }

    // MARK: - Заготовка термина

    private var draftCard: some View {
        DictionaryCard(tinted: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Новый термин").font(.headline)
                if let variants = model.draft?.variants, !variants.isEmpty {
                    HStack(spacing: 6) {
                        Text("Слышится как").font(.callout).foregroundStyle(.secondary)
                        ForEach(variants, id: \.self) { variant in
                            Text(variant).font(.subheadline).chip()
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField(
                        "Термин латиницей",
                        text: Binding(
                            get: { model.draft?.canonical ?? "" },
                            set: { model.draft?.canonical = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commitDraft() }
                    Button("Добавить") { model.commitDraft() }
                        .disabled(model.draft?.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
                    Button("Отмена") { model.draft = nil }
                }
            }
        }
    }

    // MARK: - Отмена удаления

    @ViewBuilder
    private var undoBar: some View {
        if let removed = model.removed {
            HStack(spacing: 10) {
                Text("Удалён «\(removed.term.canonical)»").font(.callout)
                Button("Вернуть") { model.undoRemove() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // Тени внутри окна нет: полоса отделяется от контента стеклом, а не размытым пятном.
            .glassPanel(in: Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Вход из меню

    private func apply(_ requested: DictionaryFocus?, proxy: ScrollViewProxy) {
        guard let requested else { return }
        switch requested {
        case .lastDictation:
            model.showsDictation = true
        case .corrections:
            withAnimation { proxy.scrollTo(Self.correctionsAnchor, anchor: .top) }
        }
        focus = nil
    }
}

// MARK: - Карточка термина

private struct TermCard: View {
    let term: DictionaryEditorModel.Term
    @Binding var canonical: String
    @Binding var stem: Bool
    let onEdit: () -> Void
    let onAddVariant: (String) -> Void
    let onRemoveVariant: (String) -> Void
    let onGenerate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DictionaryCard {
            VStack(alignment: .leading, spacing: 8) {
                header
                variants
                footer
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Термин латиницей", text: $canonical)
                .textFieldStyle(.plain)
                // Термин — главное в карточке, и заголовкам блоков (`.headline`, жирный 13)
                // он проигрывать не должен. `.title3` — ближайший семантический стиль,
                // который крупнее; ручной размер тут запрещён.
                .font(.title3)
                .onChange(of: canonical) { _, _ in onEdit() }

            if term.isGenerating {
                ProgressView().controlSize(.small)
            }
            // Место под кнопки держим всегда: иначе карточка дёргалась бы под курсором.
            HStack(spacing: 4) {
                Button(action: onGenerate) {
                    Image(systemName: "sparkles")
                }
                .help("Сгенерировать варианты заново")
                .disabled(term.isGenerating)

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                }
                .help("Удалить термин")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
        }
    }

    private var variants: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(term.variants, id: \.self) { variant in
                VariantChip(text: variant) { onRemoveVariant(variant) }
            }
            AddVariantChip(onAdd: onAddVariant)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Склонения", isOn: $stem)
                .toggleStyle(.checkbox)
                .onChange(of: stem) { _, _ in onEdit() }
                .help("Термин склоняется: «деплой» ловит и «деплоя», и «деплою»")

            if let note = term.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if term.variants.isEmpty, !term.isGenerating {
                Text("Вариантов нет — замены не будет")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Чипсы

/// Плоская заливка чипа: карточка уже стеклянная, а стекло на стекле сэмплировать нечего.
/// Радиус фиксированный — чипы плавают в середине карточки, концентричность им не считают.
private struct Chip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension View {
    fileprivate func chip() -> some View { modifier(Chip()) }
}

/// Вариант: крестик проявляется под курсором, но место под него занято всегда —
/// иначе чипсы разъезжались бы от наведения.
private struct VariantChip: View {
    let text: String
    let onRemove: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.subheadline)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help("Убрать вариант")
        }
        .chip()
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
    }
}

/// Чипс-«плюс»: по нажатию превращается в поле ввода прямо в ряду вариантов.
private struct AddVariantChip: View {
    let onAdd: (String) -> Void

    @State private var isEditing = false
    @State private var text = ""
    @SwiftUI.FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("вариант", text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .frame(width: 110)
                .chip()
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand { close() }
                .onAppear { isFocused = true }
        } else {
            Button {
                isEditing = true
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .chip()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Добавить вариант вручную")
        }
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            close()
            return
        }
        onAdd(value)
        text = ""
        // Поле остаётся открытым: варианты добавляют пачкой, а не по одному.
        isFocused = true
    }

    private func close() {
        text = ""
        isEditing = false
    }
}

/// Подсказка: слово, число диктовок с ним и два решения — взять или больше не предлагать.
private struct CorrectionChip: View {
    let learned: LearnedCorrection
    let onAccept: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Обе стороны правки: без «услышал» непонятно, за что чипс отвечает, —
            // в словаре это и есть вариант, а не каноническая форма.
            Text(learned.correction.heard)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .strikethrough()
            Text(learned.correction.meant).font(.subheadline)
            Button(action: onAccept) {
                Image(systemName: "plus.circle.fill").font(.subheadline)
            }
            .buttonStyle(.plain)
            .help("Добавить в словарь")
            Button(action: onIgnore) {
                Image(systemName: "xmark.circle").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Не запоминать эту правку")
        }
        .chip()
    }
}

// MARK: - Общая оболочка

/// Плашка редактора: стекло общей основы, радиус 10, без тени. Тонировка заготовки —
/// плоская заливка поверх стекла, а не второй его слой.
private struct DictionaryCard<Content: View>: View {
    var tinted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if tinted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .glassPanel(cornerRadius: 10)
    }
}

// MARK: - Раскладка чипсов

/// Ряды чипсов с переносом: SwiftUI такого стека не даёт, а `LazyVGrid` рвёт строку
/// по колонкам фиксированной ширины — варианты разной длины в него не ложатся.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, advance > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
