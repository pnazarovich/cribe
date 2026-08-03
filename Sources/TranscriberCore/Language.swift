import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    case ru
    case uk

    public var whisperModel: String {
        self == .ru ? "openai_whisper-large-v3-v20240930_turbo" : WhisperModel.large
    }

    public var displayName: String {
        self == .ru ? "Русский" : "Українська"
    }
}

/// Единственная точка выбора модели Whisper для сессии. Обычно её задаёт язык
/// (`Language.whisperModel`), но «смешанная речь» уводит русские сессии с turbo на large-v3:
/// turbo заметно слабее на украинском (22.8 % WER против 13.7 %), и украинские слова
/// внутри русской диктовки теряются именно на нём.
public enum WhisperModel {
    /// Большая модель — она же основная для украинского.
    public static let large = "openai_whisper-large-v3"

    public static func name(for language: Language, mixedSpeech: Bool) -> String {
        language == .ru && mixedSpeech ? large : language.whisperModel
    }
}
