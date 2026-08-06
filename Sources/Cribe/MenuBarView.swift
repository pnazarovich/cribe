import AppKit
import SwiftUI
import CribeCore

/// Содержимое меню в строке состояния. Стиль `.menu` — нативное NSMenu, поэтому
/// внутри допустимы только меню-совместимые вью: Text, Button, Toggle, Picker, Menu, Section, Divider.
struct MenuBarView: View {
    @ObservedObject var core: AppCore
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @ObservedObject var suggester: TermSuggester
    @ObservedObject var updates: UpdateController

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Сколько символов диктовки помещаем в пункт истории.
    private static let historyTitleLimit = 48

    var body: some View {
        // Плановая проверка нашла новую версию. Само по себе окно Sparkle фоновому
        // приложению открылось бы позади чужих — поэтому оно ждёт этой строки, и щелчок
        // по ней открывает его уже поверх всего (см. `UpdateController`).
        if let version = updates.pendingVersion {
            Button("Обновление \(version) — установить…") { updates.checkForUpdates() }

            Divider()
        }

        Text(status)

        Divider()

        // Смешанная речь меняет то, как распознаётся диктовка, — в меню это должно быть видно
        // там же, где язык, иначе непонятно, ждать украинских слов или нет.
        Picker(settings.mixedSpeech ? "Язык · RU+UK" : "Язык", selection: $settings.language) {
            ForEach(Language.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
            }
        }

        MicrophoneMenu(settings: settings)

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
                    // Копировать нечего — ведём туда, где запись можно разобрать заново.
                    Button(Self.title(for: item)) {
                        item.text.isEmpty ? openHistory() : copy(item.text)
                    }
                }

                Divider()
            }

            // Окно, а не строка меню: только там видно длительность записи и живёт
            // повторное распознавание — единственный путь вернуть потерянную диктовку.
            Button("Открыть окно истории…") { openHistory() }
        }

        Divider()

        Button("Словарь…") { openDictionary() }

        // Разбор «я сказал X, получилось Y» начинается отсюда: слова последней диктовки
        // становятся вариантами в два клика, без переписывания их руками.
        Button("Добавить из последней диктовки") { openDictionary(.lastDictation) }
            .disabled(controller.lastOriginal == nil && history.items.isEmpty)

        // Пункт появляется, только когда есть что предложить: во время диктовки подсказки
        // не всплывают ничем и никогда — это тихая строка в меню, а не окно поверх работы.
        if !suggester.suggestions.isEmpty {
            Button("Предложения (\(suggester.suggestions.count))") { openDictionary(.suggestions) }
        }

        // Не `SettingsLink`: он открывает окно, но приложение не активирует, и настройки
        // появлялись позади чужих окон. Тот же путь через презентер, что и у остальных окон.
        Button("Настройки…") {
            WindowPresenter.shared.present { openSettings() }
        }
        // Окно Sparkle поднимает сама: проверку начал человек, и фоновое приложение она
        // в этом случае активирует. Пункт гаснет, пока предыдущая проверка не закончилась.
        Button("Проверить обновления…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
        // Ручной вход в онбординг: разрешения и модели могут понадобиться и позже,
        // а автоматически окно показывается только на первом запуске.
        Button("Первичная настройка…") {
            WindowPresenter.shared.present(WindowID.onboarding) {
                openWindow(id: WindowID.onboarding)
            }
        }

        Divider()

        Button("Выход") { NSApp.terminate(nil) }
    }

    /// Пока сессия идёт, показываем её язык: переключение на живой записи меняет настройку,
    /// но не то, чем распознаётся текущая диктовка.
    private var displayLanguage: Language {
        controller.activeSessionLanguage ?? settings.language
    }

    /// Метка перевода в строке записи: сессия правого ⌥ переводит вопреки выключенному
    /// тумблеру, поэтому переопределение сессии сильнее настройки (как и в панели).
    private var translateMark: String {
        (controller.activeSessionTranslate ?? settings.translateToEnglish) ? " → EN" : ""
    }

    private var status: String {
        switch controller.state {
        case .idle: return "Готов · \(displayLanguage.displayName)"
        case .preparingModel(.downloading(let progress)): return "Качаю модель… \(Int(progress * 100))%"
        case .preparingModel(.warming): return "Готовлю модель…"
        case .recording: return "● Идёт запись · \(displayLanguage.displayName)\(translateMark)"
        case .transcribing: return "Распознаю…"
        case .cleaning: return "✨ Чищу…"
        case .inserted: return "✓ Вставлено"
        case .carded: return "⤷ В карточку"
        case .cancelled: return "✕ Отменено"
        case .degraded(let reason): return "⚠️ \(reason)"
        case .error(let message): return "⚠️ \(message)"
        }
    }

    private func openHistory() {
        WindowPresenter.shared.present(WindowID.history) {
            openWindow(id: WindowID.history)
        }
    }

    private func openDictionary(_ focus: DictionaryFocus? = nil) {
        core.dictionaryFocus = focus
        WindowPresenter.shared.present(WindowID.dictionary) {
            openWindow(id: WindowID.dictionary)
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Пункт меню — одна строка: переносы схлопываем, хвост обрезаем.
    /// Диктовка без текста — та, из которой распознавание ничего не вытащило: её запись
    /// лежит в истории и ждёт повтора, а пустая строка в меню была бы просто дырой.
    private static func title(for item: HistoryItem) -> String {
        guard !item.text.isEmpty else { return "⚠️ не распозналось — открыть окно истории" }
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
///
/// Пункты — кнопки, а не `Picker`: в стиле `.menu` (нативное NSMenu) привязка `Picker`
/// молча не срабатывает — выбор в меню отмечался, а в настройки не доезжал.
private struct MicrophoneMenu: View {
    @ObservedObject var settings: AppSettings

    /// Источник тот же, из которого захват резолвит устройство (`AVCaptureDevice`), а не HAL:
    /// иначе в списке оказались бы строки, на которых галочка стоит, а запись идёт мимо.
    @State private var devices = AudioDeviceList.captureInputDevices()

    /// Панель «Звук» → вкладка «Вход».
    private static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")

    var body: some View {
        Menu("Микрофон") {
            Button(Self.title("Системный по умолчанию", selected: settings.inputDeviceUID == nil)) {
                settings.inputDeviceUID = nil
            }
            ForEach(devices) { device in
                Button(Self.title(device.name, selected: settings.inputDeviceUID == device.uid)) {
                    settings.inputDeviceUID = device.uid
                }
            }
            // Выбранного микрофона в системе больше нет: захват пишет с системного входа,
            // и молчать об этом нельзя — иначе непонятно, почему звук идёт «не оттуда».
            if let uid = settings.inputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                Text("⚠️ Выбранный микрофон недоступен — пишу с системного")
            }

            Divider()

            Button("Сменить микрофон в настройках macOS…") {
                guard let soundSettings = Self.soundSettings else { return }
                NSWorkspace.shared.open(soundSettings)
            }
        }
        .onAppear { devices = AudioDeviceList.captureInputDevices() }
    }

    /// Галочка префиксом: у кнопки в NSMenu своего состояния выбора нет, а отступ у
    /// невыбранных строк держит колонку ровной.
    private static func title(_ name: String, selected: Bool) -> String {
        (selected ? "✓ " : "    ") + name
    }
}
