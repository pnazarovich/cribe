import SwiftUI
import TranscriberCore

/// Что показать в редакторе сразу после открытия из меню.
enum DictionaryFocus: Equatable {
    case lastDictation
    case suggestions
}

/// Редактор словаря: карточка на термин, варианты — снимаемыми чипсами.
///
/// Кнопки «Сохранить» нет: правка уезжает в файл сама через `Debounce`. Это и есть
/// главное отличие от прежней таблицы — добавить термин теперь значит написать его
/// латиницей и подождать, пока варианты сгенерируются, а не выдумывать их руками.
struct DictionaryEditorView: View {
    @ObservedObject var suggester: TermSuggester

    /// Текст последней диктовки для панели «добавить из диктовки»; nil — диктовок не было.
    let lastDictation: String?
    /// Разовый сигнал «открыли из меню за этим»; редактор его сам и гасит.
    @Binding var focus: DictionaryFocus?

    @StateObject private var model: DictionaryEditorModel

    @State private var newTerm = ""

    /// Якорь прокрутки к подсказкам: из меню в редактор приходят именно за ними.
    private static let suggestionsAnchor = "suggestions"

    init(
        dictionary: UserDictionary,
        settings: AppSettings,
        suggester: TermSuggester,
        lastDictation: String?,
        focus: Binding<DictionaryFocus?>
    ) {
        self.suggester = suggester
        self.lastDictation = lastDictation
        _focus = focus
        _model = StateObject(
            wrappedValue: DictionaryEditorModel(
                dictionary: dictionary,
                settings: settings,
                suggester: suggester
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        addRow
                        if !suggester.suggestions.isEmpty {
                            suggestionsCard.id(Self.suggestionsAnchor)
                        }
                        if model.showsDictation { dictationCard }
                        if model.draft != nil { draftCard }
                        terms
                    }
                    .padding(14)
                }
                .onAppear { apply(focus, proxy: proxy) }
                .onChange(of: focus) { _, focus in apply(focus, proxy: proxy) }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .overlay(alignment: .bottom) { undoBar }
        .animation(.easeOut(duration: 0.18), value: model.removed)
        .animation(.easeOut(duration: 0.18), value: model.draft)
        .onAppear { model.reload() }
        // Окно закрывают, не дожидаясь таймера, — недописанное дописываем сами.
        .onDisappear { model.flush() }
    }

    // MARK: - Шапка

    private var toolbar: some View {
        HStack(spacing: 10) {
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
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))

            Spacer(minLength: 8)
            saveMark
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Тихая отметка вместо кнопки: сохранение — не событие, о котором надо кричать,
    /// но провал записи молчать не имеет права.
    @ViewBuilder
    private var saveMark: some View {
        switch model.saveState {
        case .idle:
            EmptyView()
        case .editing:
            Text("…").font(.caption).foregroundStyle(.tertiary)
        case .saved:
            Label("сохранено", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        }
    }

    // MARK: - Добавление

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Новый термин (латиницей)", text: $newTerm)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTerm)
            Button("Добавить", action: addTerm)
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                model.showsDictation.toggle()
            } label: {
                Label("Из последней диктовки", systemImage: "waveform")
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
                Text(model.search.isEmpty ? "Словарь пуст" : "Ничего не найдено")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
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

    // MARK: - Подсказки

    private var suggestionsCard: some View {
        DictionaryCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Предложения (\(suggester.suggestions.count))", systemImage: "lightbulb")
                    .font(.system(size: 12, weight: .semibold))
                Text("Эти слова повторяются в диктовках, но словарь их не знает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(suggester.suggestions) { candidate in
                        SuggestionChip(
                            candidate: candidate,
                            onAccept: { model.acceptSuggestion(candidate) },
                            onIgnore: { model.ignoreSuggestion(candidate) }
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
                    Label("Из последней диктовки", systemImage: "waveform")
                        .font(.system(size: 12, weight: .semibold))
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(words(in: text), id: \.self) { word in
                            Button {
                                model.draftFromDictation(word: word)
                            } label: {
                                Text(word)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("Диктовок ещё не было.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func words(in text: String) -> [String] {
        DictionaryEditorModel.words(in: text, known: TermSuggester.knownTokens(model.terms.map(\.entry)))
    }

    // MARK: - Заготовка термина

    private var draftCard: some View {
        DictionaryCard(tinted: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Новый термин").font(.system(size: 12, weight: .semibold))
                if let variants = model.draft?.variants, !variants.isEmpty {
                    HStack(spacing: 6) {
                        Text("Слышится как").font(.caption).foregroundStyle(.secondary)
                        ForEach(variants, id: \.self) { variant in
                            Text(variant)
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Вход из меню

    private func apply(_ requested: DictionaryFocus?, proxy: ScrollViewProxy) {
        guard let requested else { return }
        switch requested {
        case .lastDictation:
            model.showsDictation = true
        case .suggestions:
            withAnimation { proxy.scrollTo(Self.suggestionsAnchor, anchor: .top) }
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

    var body: some View {
        DictionaryCard {
            VStack(alignment: .leading, spacing: 8) {
                header
                variants
                footer
            }
        }
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Термин латиницей", text: $canonical)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
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
        HStack(spacing: 10) {
            Toggle("склонения", isOn: $stem)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .onChange(of: stem) { _, _ in onEdit() }
                .help("Термин склоняется: «деплой» ловит и «деплоя», и «деплою»")

            if let note = term.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if term.variants.isEmpty, !term.isGenerating {
                Text("вариантов нет — замены не будет")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
    }
}

// MARK: - Чипсы

/// Вариант: крестик проявляется под курсором, но место под него занято всегда —
/// иначе чипсы разъезжались бы от наведения.
private struct VariantChip: View {
    let text: String
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help("Убрать вариант")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .onHover { isHovered = $0 }
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
                .font(.system(size: 12))
                .frame(width: 110)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand { close() }
                .onAppear { isFocused = true }
        } else {
            Button {
                isEditing = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
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
private struct SuggestionChip: View {
    let candidate: TermCandidate
    let onAccept: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(candidate.token).font(.system(size: 12))
            Text("\(candidate.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(action: onAccept) {
                Image(systemName: "plus.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Добавить в словарь")
            Button(action: onIgnore) {
                Image(systemName: "xmark.circle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Больше не предлагать")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.yellow.opacity(0.18)))
    }
}

// MARK: - Общая оболочка

/// Плашка редактора: то же скруглённое стекло, что у карточек диктовки, но в лёгком
/// исполнении — это обычное окно, материала за окном тут нет и быть не должно.
private struct DictionaryCard<Content: View>: View {
    var tinted = false
    @ViewBuilder let content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tinted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                          : AnyShapeStyle(Material.regular)))
            .overlay(shape.strokeBorder(.primary.opacity(0.08)))
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
