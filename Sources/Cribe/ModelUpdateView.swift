import SwiftUI
import CribeCore

/// Экран после обновления: распознавание сменило модель, и новую надо скачать.
///
/// Отдельное окно, а не строчка в настройках, потому что без модели приложение не работает
/// вовсе — а человек в этот момент ничего не просил и не знает, что случилось. Экран обязан
/// сказать три вещи: что поменялось, зачем, и сколько это займёт. Кнопка одна.
///
/// Полтора гигабайта старых весов удаляются тут же — но только по нажатию: это чужие файлы,
/// и распоряжаться ими без спроса нельзя.
struct ModelUpdateView: View {
    @ObservedObject var install: ModelInstall
    @ObservedObject var settings: AppSettings
    /// Зовётся, когда модель готова и человек закрыл экран.
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var legacyBytes: Int64 = 0
    @State private var legacyRemoved = false
    @State private var legacyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider().opacity(0.5)
            progressBlock
            if legacyBytes > 0 || legacyRemoved { legacyBlock }
            styleBlock
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 520, height: 620)
        .glassWindow()
        .onAppear {
            install.refresh()
            legacyBytes = LegacyWhisperCache.shared.bytesOnDisk()
            // Качать начинаем сами: экран показан ровно потому, что без модели работать
            // нечем, и лишнее нажатие тут ничего не решает.
            install.download()
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CrabMark(size: 36)
                Text("Новое распознавание")
                    .font(.title.weight(.semibold))
            }
            Text(
                "Cribe перешёл на модель Parakeet от NVIDIA. Она слышит точнее — особенно "
                    + "падежи и окончания — и работает вдесятеро быстрее прежней: диктовка "
                    + "обрабатывается за доли секунды вместо нескольких секунд."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Загрузка

    @ViewBuilder
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch install.state {
            case .missing:
                line("Модель ещё не скачана", systemImage: "arrow.down.circle")
                Button("Скачать модель") { install.download() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

            case .downloading(let fraction):
                line("Скачиваю модель", systemImage: "arrow.down.circle")
                ProgressView(value: fraction)
                Text(
                    "\(Int(fraction * 100)) % из ≈"
                        + ByteCountFormatter.string(
                            fromByteCount: ModelInstall.approximateBytes, countStyle: .file
                        )
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            case .preparing:
                line("Готовлю модель к работе", systemImage: "cpu")
                // Полоса без значения: компиляция под Neural Engine о своём прогрессе
                // не сообщает, и двигать полосу наугад было бы враньём.
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Разовая подготовка под Neural Engine — примерно минута.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .ready:
                line("Модель готова", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Скачивается один раз. Дальше распознавание идёт без интернета.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .failed(let message):
                line("Скачать не удалось", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Попробовать ещё раз") { install.download() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Индикатор записи

    /// Заодно показываем новое оформление капсулы: экран всё равно открыт, а иначе про
    /// бегущую строку узнают только те, кто зайдёт в настройки.
    private var styleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            Text("Заодно: что показывать, пока идёт запись")
                .font(.headline)
            PillStyleChooser(selection: $settings.pillStyle)
        }
    }

    // MARK: - Старые веса

    private var legacyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            if legacyRemoved {
                line("Старые модели удалены", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Старые модели Whisper")
                        Text(
                            ByteCountFormatter.string(fromByteCount: legacyBytes, countStyle: .file)
                                + " — больше не нужны"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Удалить") { removeLegacy() }
                }
            }
            if let legacyError {
                Text(legacyError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func removeLegacy() {
        do {
            legacyError = nil
            try LegacyWhisperCache.shared.remove()
            legacyRemoved = true
            legacyBytes = 0
        } catch {
            legacyError = error.localizedDescription
        }
    }

    // MARK: - Низ

    @ViewBuilder
    private var footer: some View {
        HStack {
            // Закрыть можно всегда: загрузка живёт в движке и продолжится без окна.
            // Но пока модель не готова, кнопка обычная — «Готово» на недокачанной модели
            // было бы обещанием, которого никто не давал.
            if install.isReady {
                Spacer()
                Button("Готово") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("Можно закрыть — загрузка продолжится в фоне.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { finish() }
                    .controlSize(.large)
            }
        }
    }

    private func finish() {
        onDone()
        dismiss()
    }

    private func line(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
    }
}
