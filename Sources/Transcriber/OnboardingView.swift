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
    @StateObject private var downloader = ModelDownloader()

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
            Text("Диктовка по ⌥` — три шага, и можно начинать. Четвёртый — по желанию.")
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
            Text("Без него текст останется в буфере обмена: ⌘V придётся нажимать вручную.")
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
        card(number: 3, title: "Модели распознавания", done: downloader.isFinished) {
            Text("Около 4.6 ГБ на два языка. Можно пропустить — модель скачается при первой диктовке.")
                .foregroundStyle(.secondary)
            ForEach(Language.allCases, id: \.self) { language in
                HStack(spacing: 10) {
                    Text(language.displayName)
                        .frame(width: 90, alignment: .leading)
                    ProgressView(value: downloader.progress[language] ?? 0)
                }
            }
            if let error = downloader.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button("Скачать") { Task { await downloader.download(engine: engine) } }
                .disabled(downloader.isRunning)
        }
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
                || KeychainStore.getString(KeychainStore.apiKeyAccount)?.isEmpty == false
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// Загрузка моделей обоих языков: прогресс приходит из фоновых потоков — сводим на главный.
@MainActor
private final class ModelDownloader: ObservableObject {
    @Published private(set) var progress: [Language: Double] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?

    var isFinished: Bool {
        Language.allCases.allSatisfy { (progress[$0] ?? 0) >= 1 }
    }

    func download(engine: WhisperEngine) async {
        isRunning = true
        error = nil
        // Последовательно: две модели по несколько гигабайт параллельно только мешают друг другу.
        for language in Language.allCases {
            do {
                try await engine.prepare(language: language) { [weak self] state in
                    Task { @MainActor in self?.apply(state, for: language) }
                }
                progress[language] = 1
            } catch {
                self.error = error.localizedDescription
            }
        }
        isRunning = false
    }

    private func apply(_ state: ASRModelState, for language: Language) {
        switch state {
        case .notLoaded: progress[language] = 0
        case .downloading(let fraction): progress[language] = fraction
        // Загрузка в память — скачивание уже позади, полоса стоит на максимуме.
        case .loading, .ready: progress[language] = 1
        }
    }
}
