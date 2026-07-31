import SwiftUI
import TranscriberCore

/// Редактор пользовательского словаря: таблица «термин / варианты / склонения».
/// Правки живут в локальных строках и уезжают в JSON только по «Сохранить».
struct DictionaryEditorView: View {
    let dictionary: UserDictionary

    @State private var rows: [EditableEntry] = []
    @State private var selection: Set<UUID> = []
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            Table(of: EditableEntry.self, selection: $selection) {
                TableColumn("Термин (латиница)") { row in
                    TextField("", text: binding(row, \.canonical))
                }
                TableColumn("Варианты через запятую") { row in
                    TextField("", text: binding(row, \.variants))
                }
                TableColumn("Склонения") { row in
                    Toggle("", isOn: binding(row, \.stem)).labelsHidden()
                }
                .width(90)
            } rows: {
                ForEach(rows) { TableRow($0) }
            }

            HStack(spacing: 8) {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Добавить термин")

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                .help("Удалить выбранные")

                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 320)
        .onAppear { rows = dictionary.entries.map(EditableEntry.init) }
    }

    /// Ячейки таблицы получают элемент, а не биндинг, — сводим правку к индексу по id.
    private func binding<Value>(
        _ row: EditableEntry,
        _ keyPath: WritableKeyPath<EditableEntry, Value>
    ) -> Binding<Value> {
        Binding(
            get: { rows.first { $0.id == row.id }?[keyPath: keyPath] ?? row[keyPath: keyPath] },
            set: { value in
                guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
                rows[index][keyPath: keyPath] = value
            }
        )
    }

    private func add() {
        let row = EditableEntry()
        rows.append(row)
        selection = [row.id]
        note = nil
    }

    private func deleteSelected() {
        rows.removeAll { selection.contains($0.id) }
        selection = []
        note = nil
    }

    private func save() {
        let entries = rows.compactMap(\.entry)
        dictionary.replace(entries: entries)
        // Строки без термина отбрасываются — показываем итог таким, каким он лёг в файл.
        rows = entries.map(EditableEntry.init)
        note = dictionary.lastSaveError.map { "Не сохранено: \($0.localizedDescription)" } ?? "Сохранено"
    }
}

/// Строка таблицы: варианты редактируются одной строкой через запятую.
struct EditableEntry: Identifiable {
    let id: UUID
    var canonical: String
    var variants: String
    var stem: Bool

    init(_ entry: DictionaryEntry) {
        id = entry.id
        canonical = entry.canonical
        variants = entry.variants.joined(separator: ", ")
        stem = entry.stem
    }

    init() {
        id = UUID()
        canonical = ""
        variants = ""
        stem = true
    }

    /// Без канонической формы запись бессмысленна — такие строки в словарь не попадают.
    var entry: DictionaryEntry? {
        let term = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let parsed = variants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return DictionaryEntry(id: id, canonical: term, variants: parsed, stem: stem)
    }
}
