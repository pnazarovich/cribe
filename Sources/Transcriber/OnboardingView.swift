import AVFoundation
import AppKit
import SwiftUI
import TranscriberCore

/// Первый запуск: микрофон, Универсальный доступ и загрузка моделей.
struct OnboardingView: View {
    let engine: WhisperEngine
    /// Зовётся при появлении окна: флаг первого запуска гасит факт показа, а не намерение.
    let onShown: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Загрузчик один на приложение: то же состояние показывают настройки.
    @ObservedObject private var downloader = ModelDownloader.shared

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = TextInserter.hasAccessibility
    @State private var gptAuthorized = false

    private var micGranted: Bool { micStatus == .authorized }

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    private static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройка Transcriber")
                .font(.title2.weight(.semibold))
            Text("Диктовка по правому ⌘ — три шага, и можно начинать. Четвёртый — по желанию.")
                .foregroundStyle(.secondary)

            micCard
            accessibilityCard
            modelsCard
            gptCard

            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: onShown)
        // Разрешения выдаются в системных окнах — состояние подтягиваем опросом.
        .task { await pollPermissions() }
    }

    // MARK: - Шаги

    private var micCard: some View {
        card(number: 1, title: "Микрофон", done: micGranted) {
            Text("Нужен для записи речи. Распознавание идёт на этом компьютере.")
                .foregroundStyle(.secondary)
            if !micGranted {
                HStack {
                    Button("Разрешить доступ") {
                        Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
                    }
                    // После отказа системный запрос больше не показывает окно — остаётся
                    // только тумблер в System Settings.
                    if micStatus == .denied, let url = Self.microphoneSettingsURL {
                        Button("Открыть System Settings") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    private var accessibilityCard: some View {
        card(number: 2, title: "Универсальный доступ", done: accessibilityGranted) {
            Text("Без него не работает правый ⌘, а текст останется в буфере обмена: ⌘V вручную.")
                .foregroundStyle(.secondary)
            if !accessibilityGranted {
                HStack {
                    Button("Запросить") { TextInserter.requestAccessibility() }
                    if let url = Self.accessibilitySettingsURL {
                        Button("Открыть System Settings") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    private var modelsCard: some View {
        card(number: 3, title: "Модели распознавания", done: modelsInstalled) {
            Text("Каждый язык качается отдельно: русский ≈1,5 ГБ, українська ≈2,9 ГБ. "
                + "Можно пропустить — модель скачается при первой диктовке.")
                .foregroundStyle(.secondary)
            ForEach(Language.allCases, id: \.self) { language in
                HStack(spacing: 10) {
                    Text(language.displayName)
                        .frame(width: 90, alignment: .leading)
                    modelState(language)
                }
            }
        }
    }

    /// Состояние и кнопка одного языка. Тот же набор, что в настройках, только теснее.
    @ViewBuilder
    private func modelState(_ language: Language) -> some View {
        switch downloader.states[language] ?? .missing {
        case .missing:
            Button("Скачать") { Task { await downloader.download(language, engine: engine) } }
        case let .downloading(fraction):
            ProgressView(value: fraction)
            Button("Отмена") { downloader.cancel(language) }
        case .installed:
            Label("Скачана", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            Button("Повторить") { Task { await downloader.download(language, engine: engine) } }
        }
    }

    private var modelsInstalled: Bool {
        Language.allCases.allSatisfy { downloader.states[$0]?.isInstalled == true }
    }

    private var gptCard: some View {
        card(number: 4, title: "GPT-авторизация (опционально)", done: gptAuthorized) {
            Text("""
                Без неё диктовка работает целиком на этом компьютере. \
                Авторизация включает AI-чистку текста и перевод на английский: \
                вход через ChatGPT или ключ OpenAI задаётся в «Настройки… → AI».
                """)
                .foregroundStyle(.secondary)
            Button("Открыть настройки") { Self.openSettings() }
        }
    }

    /// `SettingsLink` программно не нажимается, поэтому шлём то же действие, что и пункт
    /// «Настройки…» в меню приложения. Имя селектора менялось между версиями macOS —
    /// пробуем оба и молча выходим, если ни один не принят: ручной путь назван в тексте карточки.
    private static func openSettings() {
        NSApp.activate()
        for name in ["showSettingsWindow:", "showPreferencesWindow:"]
        where NSApp.sendAction(Selector((name)), to: nil, from: nil) {
            return
        }
    }

    // MARK: - Каркас карточки

    private func card<Content: View>(
        number: Int,
        title: String,
        done: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(done ? "✓" : "\(number)")
                    .font(.headline)
                    .foregroundStyle(done ? Color.green : .secondary)
                    .frame(width: 18)
                Text(title).font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func pollPermissions() async {
        while !Task.isCancelled {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityGranted = TextInserter.hasAccessibility
            // Авторизоваться можно любым из двух способов — засчитываем оба.
            gptAuthorized = await CodexAuth.shared.isAuthorized()
                || SecretStore.getString(SecretStore.apiKeyAccount)?.isEmpty == false
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
