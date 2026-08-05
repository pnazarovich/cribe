import AVFoundation
import AppKit
import SwiftUI
import TranscriberCore

/// Первый запуск: что это за программа, три клавиши и путь до первой диктовки.
///
/// Одно окно, шаги вертикальным списком с галочками. Развёрнут ровно один — текущий;
/// сделанные и будущие свёрнуты в строку. Мастер с «Далее» здесь был бы враньём: шаги
/// выполняются в системных окнах и в чужом браузере, вернуться к любому надо в любой
/// момент, а видеть, сколько осталось, — всё время.
struct OnboardingView: View {
    let engine: WhisperEngine
    @ObservedObject var settings: AppSettings
    /// Зовётся при появлении окна: флаг первого запуска гасит факт показа, а не намерение.
    let onShown: () -> Void
    /// Accessibility выдают в System Settings уже на работающем приложении — тапы правых
    /// ⌘/⌥ после этого надо поднять, не дожидаясь перезапуска.
    let onAccessibilityGranted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    /// Общий на всё приложение: тот же объект показывает модели в настройках, и загрузка,
    /// начатая здесь, не обрывается закрытым окном.
    @ObservedObject private var downloader = ModelDownloader.shared
    @StateObject private var signIn = CodexSignInModel()

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = TextInserter.hasAccessibility
    @State private var apiKeyPresent = false
    @State private var modelsSkipped = false
    @State private var aiSkipped = false

    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    private static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    private var progress: OnboardingProgress {
        OnboardingProgress(
            micGranted: micStatus == .authorized,
            accessibilityGranted: accessibilityGranted,
            modelInstalled: Language.allCases.contains { isInstalled($0) },
            // Ключ OpenAI — такая же настроенность, как и вход в ChatGPT: шаг закрывают оба.
            gptAuthorized: signIn.isAuthorized || apiKeyPresent,
            modelsSkipped: modelsSkipped,
            aiSkipped: aiSkipped
        )
    }

    private func state(of language: Language) -> ModelDownloadState {
        downloader.states[language] ?? .missing
    }

    private func isInstalled(_ language: Language) -> Bool {
        if case .installed = state(of: language) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(OnboardingStep.allCases) { step in
                        row(step)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(24)
        // Размер фиксированный: список шагов то разворачивается, то сворачивается, и окно,
        // прыгающее под каждым нажатием, читается сломанным. Что не влезло — прокручивается.
        .frame(width: 560, height: 620)
        .onAppear {
            onShown()
            // Состояние моделей читается с диска: скачанный язык обязан стоять
            // установленным с первого кадра, а не после нажатия на «Скачать».
            downloader.refresh()
        }
        // Разрешения выдаются в системных окнах, а вход в ChatGPT — в браузере:
        // состояние подтягиваем опросом.
        .task { await poll() }
        // Закрытое окно не имеет права продолжать долбить auth.openai.com каждые пять секунд.
        .onDisappear { signIn.cancel() }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcriber")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Диктовка на русском и украинском: нажали клавишу, сказали — текст появился "
                    + "в поле с курсором, а речь распозналась прямо на этом компьютере."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                KeyCap(prefix: "правый", key: "⌘", caption: "диктовка")
                KeyCap(prefix: "правый", key: "⌥", caption: "с переводом на английский")
                KeyCap(prefix: nil, key: "esc", caption: "отмена")
            }
        }
    }

    // MARK: - Строка шага

    @ViewBuilder
    private func row(_ step: OnboardingStep) -> some View {
        let state = progress.state(of: step)
        HStack(alignment: .top, spacing: 12) {
            marker(number: step.rawValue + 1, state: state)
                .font(.title3)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.title)
                        .font(.headline)
                        .foregroundStyle(state == .pending ? .secondary : .primary)
                    Spacer()
                    if state == .done {
                        Text("готово").font(.caption).foregroundStyle(.green)
                    } else if progress.isSettled(step) {
                        // Отложенный шаг не пропадает и не притворяется сделанным: строка
                        // остаётся на месте и говорит, что к ней ещё можно вернуться.
                        Text("позже").font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Развёрнут только текущий шаг: сделанному сказать больше нечего,
                // а будущему — ещё рано.
                if state == .active {
                    body(of: step)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(state == .active ? 0.55 : 0.3),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    state == .active ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06)
                )
        }
    }

    @ViewBuilder
    private func marker(number: Int, state: OnboardingStepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active:
            Image(systemName: "\(number).circle.fill").foregroundStyle(Color.accentColor)
        case .pending:
            Image(systemName: "\(number).circle").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func body(of step: OnboardingStep) -> some View {
        switch step {
        case .microphone: microphoneBody
        case .accessibility: accessibilityBody
        case .models: modelsBody
        case .ai: aiBody
        case .ready: readyBody
        }
    }

    // MARK: - Микрофон

    @ViewBuilder
    private var microphoneBody: some View {
        caption("Нужен, чтобы слышать вас. Запись живёт до вставки текста и стирается.")
        if micStatus == .denied || micStatus == .restricted {
            caption("Доступ отклонён — включите Transcriber в списке System Settings.")
            settingsButton(Self.microphoneSettingsURL, big: true)
        } else {
            Button("Разрешить доступ") {
                Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Универсальный доступ

    @ViewBuilder
    private var accessibilityBody: some View {
        caption(
            "Без него не работают горячие клавиши и вставка: правый ⌘ не запустит запись, "
                + "а готовый текст останется в буфере обмена — вставлять придётся руками."
        )
        HStack(spacing: 10) {
            Button("Запросить доступ") { TextInserter.requestAccessibility() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            settingsButton(Self.accessibilitySettingsURL, big: false)
        }
        caption("Галочку в System Settings приложение увидит само — перезапускать не нужно.")
    }

    // MARK: - Модель

    @ViewBuilder
    private var modelsBody: some View {
        caption(
            "Языки качаются по отдельности: нужен только русский — украинские "
                + "\(Language.uk.modelSizeText) скачивать незачем. Загрузка разовая, "
                + "дальше распознавание идёт без интернета."
        )
        ForEach(Language.allCases, id: \.self) { language in
            modelRow(language)
        }
        HStack(spacing: 10) {
            Button("Позже") { modelsSkipped = true }
            caption("Первая диктовка скачает нужную модель сама.")
        }
        .font(.callout)
    }

    /// Строка одного языка: слева имя и вес, справа — то единственное, что с ним сейчас
    /// можно сделать. Кнопка языка диктовки выделена: с него первый запуск и начнётся.
    @ViewBuilder
    private func modelRow(_ language: Language) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(language.displayName)
                Text(language.modelSizeText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)

            switch state(of: language) {
            case .missing, .failed:
                Button("Скачать") {
                    Task { await downloader.download(language, engine: engine) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(language == settings.language ? Color.accentColor : Color.secondary)
                Spacer()
            case .downloading(let fraction):
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Отмена") { downloader.cancel(language) }
            case .installed(let bytes):
                Label(Self.size(bytes), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
        }
        if case .failed(let message) = state(of: language) {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - ChatGPT

    @ViewBuilder
    private var aiBody: some View {
        caption(
            "GPT расставит знаки препинания и заглавные буквы, а правый ⌥ переведёт диктовку "
                + "на английский. Без входа всё остальное работает как есть."
        )

        if let session = signIn.session {
            VStack(alignment: .leading, spacing: 8) {
                caption("Введите этот код на странице подтверждения:")
                HStack(spacing: 10) {
                    Text(session.userCode)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        TextInserter.copy(session.userCode)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Скопировать код")
                }
                Link("Открыть страницу подтверждения", destination: session.verificationURL)
                if signIn.isPolling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        caption("Ожидаю подтверждения…")
                        Spacer()
                        Button("Отмена") { signIn.cancel() }
                    }
                }
            }
        } else {
            Button("Подключить ChatGPT") { signIn.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            HStack(spacing: 10) {
                Button("Ввести API-ключ") { openAISettings() }
                Button("Пропустить") { aiSkipped = true }
                Spacer()
            }
        }

        if let message = signIn.message {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Готово

    @ViewBuilder
    private var readyBody: some View {
        Text("Нажмите правый ⌘ и говорите. Нажали ещё раз — текст в поле с курсором.")
            .fixedSize(horizontal: false, vertical: true)
        if !progress.modelInstalled {
            caption("Модели ещё нет — первая диктовка скачает её, это займёт несколько минут.")
        }
        if progress.gptAuthorized {
            caption("ChatGPT подключён — модель и усилие уже настроены, менять ничего не нужно.")
        } else {
            caption("ChatGPT можно подключить позже: «Настройки… → AI».")
        }
        Button("Попробовать") { dismiss() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    // MARK: - Мелочи

    private func caption(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func settingsButton(_ url: URL?, big: Bool) -> some View {
        if let url {
            let button = Button("Открыть System Settings") { NSWorkspace.shared.open(url) }
            if big {
                button.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                button
            }
        }
    }

    /// Настройки открываем тем же путём, что и пункт меню: `SettingsLink` программно
    /// не нажимается, а окно, открытое без презентера, рождается позади чужих.
    private func openAISettings() {
        WindowPresenter.shared.present { openSettings() }
    }

    private func poll() async {
        while !Task.isCancelled {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let trusted = TextInserter.hasAccessibility
            if trusted && !accessibilityGranted { onAccessibilityGranted() }
            accessibilityGranted = trusted
            // Вход мог случиться и мимо этого окна — в настройках или на прошлом запуске.
            await signIn.refreshStatus()
            apiKeyPresent = SecretStore.getString(SecretStore.apiKeyAccount)?.isEmpty == false
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
}

/// Клавиша так, как её видно на клавиатуре: сама клавиша плашкой, назначение — подписью.
/// Прозой («правый Command запускает диктовку») то же самое читается инструкцией к прибору.
private struct KeyCap: View {
    let prefix: String?
    let key: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                Text(prefix ?? " ")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(key)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
            }
            .frame(width: 74, height: 46)
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 100)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
