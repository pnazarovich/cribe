import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    case ru
    case uk

    public var whisperModel: String {
        self == .ru ? "openai_whisper-large-v3-v20240930_turbo" : "openai_whisper-large-v3"
    }

    public var displayName: String {
        self == .ru ? "Русский" : "Українська"
    }
}
