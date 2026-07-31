import AppKit
import SwiftUI
import TranscriberCore

/// Содержимое меню в строке состояния. Стиль `.menu` — нативное NSMenu, поэтому
/// внутри допустимы только меню-совместимые вью: Text, Button, Toggle, Picker, Menu, Section, Divider.
struct MenuBarView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore

    @Environment(\.openWindow) private var openWindow

    /// Сколько символов диктовки помещаем в пункт истории.
    private static let historyTitleLimit = 48

    var body: some View {
        Text(status)

        Divider()

        Picker("Язык", selection: $settings.language) {
            ForEach(Language.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
            }
        }

        MicrophonePicker(settings: settings)

        Divider()

        Toggle("AI-чистка (GPT)", isOn: $settings.gptEnabled)
        Toggle("Перевод на английский", isOn: $settings.translateToEnglish)
        Toggle("Звуки", isOn: $settings.soundsEnabled)

        Section("Последняя диктовка") {
            Button("Скопировать оригинал") { controller.copyLastOriginal() }
                .disabled(controller.lastOriginal == nil)

            // Перевод делает GPT-слой: без него копировать нечего.
            Button("Скопировать перевод") {
                Task { await controller.translateLastAndCopy() }
            }
            .disabled(controller.lastOriginal == nil || !settings.gptEnabled)
        }

        Menu("История") {
            if history.items.isEmpty {
                Text("Пусто")
            } else {
                ForEach(history.items) { item in
                    Button(Self.title(for: item)) { copy(item.text) }
                }
            }
        }

        Divider()

        Button("Словарь…") {
            NSApp.activate()
            openWindow(id: WindowID.dictionary)
        }
        SettingsLink { Text("Настройки…") }
        // Ручной вход в онбординг: разрешения и модели могут понадобиться и позже,
        // а автоматически окно показывается только на первом запуске.
        Button("Первичная настройка…") {
            NSApp.activate()
            openWindow(id: WindowID.onboarding)
        }

        Divider()

        Button("Выход") { NSApp.terminate(nil) }
    }

    /// Пока сессия идёт, показываем её язык: переключение на живой записи меняет настройку,
    /// но не то, чем распознаётся текущая диктовка.
    private var displayLanguage: Language {
        controller.activeSessionLanguage ?? settings.language
    }

    private var status: String {
        switch controller.state {
        case .idle: return "Готов · \(displayLanguage.displayName)"
        case .preparingModel(let progress): return "Загружаю модель… \(Int(progress * 100))%"
        case .recording: return "● Идёт запись · \(displayLanguage.displayName)"
        case .transcribing: return "Распознаю…"
        case .cleaning: return "✨ Чищу…"
        case .inserted: return "✓ Вставлено"
        case .degraded(let reason): return "⚠️ \(reason)"
        case .error(let message): return "⚠️ \(message)"
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Пункт меню — одна строка: переносы схлопываем, хвост обрезаем.
    private static func title(for item: HistoryItem) -> String {
        let flat = item.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > historyTitleLimit else { return flat }
        return String(flat.prefix(historyTitleLimit)) + "…"
    }
}

/// Подменю микрофонов отдельным вью ради собственной точки обновления списка.
/// Свежесть держится двумя независимыми механизмами, чтобы не зависеть от того,
/// пересобирает ли SwiftUI содержимое NSMenu на каждом открытии:
/// 1) стартовое значение `@State` читается при создании вью;
/// 2) `onAppear` перечитывает список, когда вью показывается.
/// Перечисление CoreAudio занимает единицы миллисекунд — на открытии меню не заметно.
private struct MicrophonePicker: View {
    @ObservedObject var settings: AppSettings

    @State private var devices = AudioDeviceList.inputDevices()

    var body: some View {
        Picker("Микрофон", selection: $settings.inputDeviceUID) {
            Text("Системный по умолчанию").tag(String?.none)
            ForEach(devices) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
        }
        .onAppear { devices = AudioDeviceList.inputDevices() }
    }
}
