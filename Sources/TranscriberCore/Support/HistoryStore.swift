import Combine
import Foundation

public struct HistoryItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    public let language: Language

    public init(id: UUID = UUID(), date: Date = Date(), text: String, language: Language) {
        self.id = id
        self.date = date
        self.text = text
        self.language = language
    }
}

/// История последних диктовок (максимум 20) в UserDefaults как JSON. Новые — в начале.
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()

    public static let limit = 20
    private static let key = "history"

    private let defaults: UserDefaults

    @Published public private(set) var items: [HistoryItem]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    public func add(_ text: String, language: Language) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        items.insert(HistoryItem(text: trimmed, language: language), at: 0)
        if items.count > Self.limit {
            items.removeLast(items.count - Self.limit)
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
