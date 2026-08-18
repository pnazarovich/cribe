import AppKit
import SwiftUI
import CribeCore

/// Содержимое меню в строке состояния. Стиль `.menu` — нативное NSMenu, поэтому
/// внутри допустимы только меню-совместимые вью: Text, Button, Toggle, Picker, Menu, Section, Divider.
///
/// Состав собран по одному правилу: наверху то, за чем сюда заходят, глубже — то, что делают
/// один раз в жизни. Меню было шестнадцатью строками подряд, и в нём приходилось искать
/// глазами; в подменю уехало только по-настоящему разовое.
///
/// Частота нажатий — не то же самое, что важность. Обновления нажимают редко, но они остались
/// наверху: их вторая половина (строка «Обновление найдено») приходит сама и живёт здесь же,
/// и разносить две половины одного дела по разной глубине нельзя.
///
/// Конвейер вью НЕ наблюдает: на записи тот публикуется двенадцать раз в секунду (в состоянии
/// едет уровень микрофона), а меню от уровня не зависит ни одной строкой. Всё нужное сведено
/// в `MenuState` двумя дедуплицированными величинами — сам `controller` здесь только
/// принимает команды.
struct MenuBarView: View {
    let core: AppCore
    let controller: DictationController
    @ObservedObject var menu: MenuState
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @ObservedObject var learner: EditLearner
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

        Text(menu.status)

        Divider()

        // Язык и микрофон — то, что меняют посреди работы. Дальше от верха им не место.
        Picker("Язык", selection: $settings.language) {
            ForEach(Language.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
            }
        }

        MicrophoneMenu(settings: settings)

        Divider()

        // Два тумблера, меняющие результат следующей же диктовки. «Звуки» отсюда ушли:
        // их ставят один раз и навсегда, а место они занимали такое же.
        Toggle("AI-чистка (GPT)", isOn: $settings.gptEnabled)
        Toggle("Перевод на \(settings.translationTarget.afterOn)", isOn: $settings.translateToEnglish)

        Divider()

        Menu("Последняя диктовка") {
            Button("Скопировать оригинал") { controller.copyLastOriginal() }
                .disabled(!menu.hasDictation)

            // Перевод делает GPT-слой: без него копировать нечего.
            Button("Скопировать перевод") {
                Task { await controller.translateLastAndCopy() }
            }
            .disabled(!menu.hasDictation || !settings.gptEnabled)

            Divider()

            // Разбор «я сказал X, получилось Y»: слова последней диктовки становятся
            // вариантами в два клика, без переписывания их руками.
            Button("Слова в словарь…") { openDictionary(.lastDictation) }
                .disabled(!menu.hasDictation && history.items.isEmpty)
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

        Button("Словарь…") { openDictionary() }

        // Строка появляется, только когда есть что показать, и остаётся наверху: замеченные
        // правки не всплывают ничем и никогда, и спрятанные в подменю они не нашлись бы вовсе.
        if !learner.pending.isEmpty {
            Button("Замеченные правки (\(learner.pending.count))") { openDictionary(.corrections) }
        }

        Divider()

        // Не `SettingsLink`: он открывает окно, но приложение не активирует, и настройки
        // появлялись позади чужих окон. Тот же путь через презентер, что и у остальных окон.
        Button("Настройки…") {
            WindowPresenter.shared.present { openSettings() }
        }

        // Обновления остаются наверху, хотя нажимают их редко. Причина не в частоте: строка
        // «Обновление найдено» приходит сама и живёт ровно здесь же (см. верх меню), и если
        // ручная проверка спрятана в подменю, то две половины одного дела оказываются
        // на разной глубине — а человек, которому «кажется, что-то давно не обновлялось»,
        // ищет её именно тут.
        //
        // Окно Sparkle поднимает сама: проверку начал человек, и фоновое приложение она
        // в этом случае активирует. Пункт гаснет, пока предыдущая проверка не закончилась.
        Button(updates.canCheck ? "Проверить обновления…" : "Проверяю обновления…") {
            updates.checkForUpdates()
        }
        .disabled(!updates.canCheck)

        // Всё, что делают в первый день и потом почти никогда.
        Menu("Ещё") {
            Toggle("Звуки старта и окончания", isOn: $settings.soundsEnabled)

            Divider()

            // Ручной вход в онбординг: разрешения и модель могут понадобиться и позже,
            // а автоматически окно показывается только на первом запуске.
            Button("Первичная настройка…") {
                WindowPresenter.shared.present(WindowID.onboarding) {
                    openWindow(id: WindowID.onboarding)
                }
            }
        }

        Divider()

        Button("Выход") { NSApp.terminate(nil) }
    }

    private func openHistory() {
        WindowPresenter.shared.present(WindowID.history) {
            openWindow(id: WindowID.history)
        }
    }

    private func openDictionary(_ focus: DictionaryFocus? = nil) {
        // Из меню разбирают последнюю диктовку — чужую строку, приведённую окном истории,
        // снимаем: иначе пункт молча показывал бы её же.
        core.dictionaryDictation = nil
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
