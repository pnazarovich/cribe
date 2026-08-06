import AppKit
import SwiftUI
import TranscriberCore

/// История диктовок с повторным распознаванием.
///
/// Окно существует ради одной вещи, которой раньше не было вовсе: если распознавание
/// потеряло речь, запись всё ещё лежит на диске, и её можно разобрать заново — другим
/// путём, а не тем же самым. Поэтому у строки с записью две кнопки, а не одна.
struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    @StateObject private var model = HistoryModel()

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 440)
            .glassWindow()
            .onAppear { model.sync(history: history) }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if history.items.isEmpty {
                    Text("Диктовок пока не было.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(history.items) { item in
                        HistoryRow(item: item, model: model, controller: controller)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Одна диктовка: текст, отметки о записи и кнопки повторного разбора.
private struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryModel
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if item.text.isEmpty {
                Text("Распознать не удалось — но запись сохранилась.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(item.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning { caption(warning, warning: true) }

            actions
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
        }
        .font(.callout)
        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if !item.text.isEmpty {
                Button("Скопировать") { HistoryModel.copy(item.text) }
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

            Spacer()

            if model.busyItem == item.id {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)

        if model.busyItem == item.id, let note = model.note {
            caption(note, warning: model.noteIsError)
        }
    }

    private func caption(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Состояние окна: какая строка сейчас пересчитывается и что ей сказать.
/// Подтверждение на скачивание large-v3 живёт здесь же — 2,9 ГБ молча не качаем.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var busyItem: UUID?
    @Published var note: String?
    @Published var noteIsError = false

    private let recordings = RecordingStore.shared
    private var bytes: Int64 = 0

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
                _ = try await controller.retranscribe(item: item, mode: mode)
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

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) c" : "\(total / 60) мин \(total % 60) c"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
