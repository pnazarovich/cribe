import Combine
import Foundation

/// Какой движок распознавания выбрал человек.
public enum RecognitionEngineChoice: String, CaseIterable, Codable, Sendable {
    /// Parakeet Ultra — русский, украинский и английский, английские названия чаще латиницей.
    case parakeet
    /// GigaAM v3 — только русский, но на чистом русском заметно точнее (GitHub #4).
    case gigaam
}

/// Решает, каким движком распознавать, и прячет это от конвейера: тот видит один движок.
///
/// GigaAM берётся, только когда он выбран, скачан и из языков отмечен один русский.
/// Украинского он не знает, а английские названия пишет кириллицей на слух («гидхаб»,
/// «экскод») — в смешанной диктовке он хуже Parakeet, и молча отдать её ему значило бы
/// испортить то, что работало. Во всех остальных случаях — Parakeet: выбор GigaAM никогда
/// не оставляет человека без распознавания, даже пока модель ещё качается.
public final class RecognitionRouter: TranscriptionEngine, @unchecked Sendable {
    public let parakeet: ParakeetEngine
    public let gigaam: GigaAMEngine
    private let gigaamInstalled: @Sendable () -> Bool
    /// Снимок настроек под замком. Маршрутизатор зовут с исполнителя гейта, а настройки
    /// пишет меню на главном потоке — читать `Set` языков напрямую было бы гонкой.
    private let lock = NSLock()
    private var choice: RecognitionEngineChoice
    private var languages: Set<Language>
    private var watch: Set<AnyCancellable> = []

    public init(
        parakeet: ParakeetEngine,
        gigaam: GigaAMEngine,
        settings: AppSettings,
        gigaamInstalled: @escaping @Sendable () -> Bool = { GigaAMEngine.isInstalled }
    ) {
        self.parakeet = parakeet
        self.gigaam = gigaam
        self.gigaamInstalled = gigaamInstalled
        choice = settings.recognitionEngine
        languages = settings.languages
        settings.$recognitionEngine.sink { [weak self] value in self?.update { $0.choice = value } }.store(in: &watch)
        settings.$languages.sink { [weak self] value in self?.update { $0.languages = value } }.store(in: &watch)
    }

    private func update(_ change: (RecognitionRouter) -> Void) {
        lock.lock(); change(self); lock.unlock()
    }

    /// Кто распознает речь на этом языке прямо сейчас.
    func usesGigaAM(for language: Language) -> Bool {
        lock.lock()
        let wanted = choice == .gigaam && languages == [.ru]
        lock.unlock()
        return wanted
            && language == .ru
            && gigaamInstalled()
    }

    private func engine(for language: Language) -> TranscriptionEngine {
        usesGigaAM(for: language) ? gigaam : parakeet
    }

    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        guard usesGigaAM(for: language) else {
            return try await parakeet.prepare(language: language, onState: onState)
        }
        do {
            try await gigaam.prepare(language: language, onState: onState)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // GigaAM скачан, но не поднимается — не хватило места на компиляцию, испорчен
            // кэш. Без запасного пути диктовка умерла бы целиком, хотя Parakeet на месте.
            try await parakeet.prepare(language: language, onState: onState)
        }
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        // Распознаёт тот, кто и правда загружен: иначе запись после неудачного подъёма
        // GigaAM ушла бы ему же, он попробовал бы подняться снова, упал — и запись пропала бы.
        let engine: TranscriptionEngine = usesGigaAM(for: language) && gigaam.isLoaded ? gigaam : parakeet
        return try await engine.transcribe(samples, language: language, prompt: prompt)
    }

    public func unload() {
        parakeet.unload()
        gigaam.unload()
    }
}
