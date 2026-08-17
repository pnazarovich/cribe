import Combine
import Foundation

public struct HistoryItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    public let language: Language
    /// Имя WAV-файла в `RecordingStore`; nil — записи нет (не хранили или уже вытеснена).
    /// Опциональные поля добавлены позже — старая история без них декодируется как есть.
    public let audio: String?
    /// Длительность записи в секундах.
    public let seconds: Double?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        language: Language,
        audio: String? = nil,
        seconds: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.language = language
        self.audio = audio
        self.seconds = seconds
    }

    /// Та же запись с другим текстом — результат повторного распознавания.
    public func replacing(text: String) -> HistoryItem {
        HistoryItem(id: id, date: date, text: text, language: language, audio: audio, seconds: seconds)
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

    /// Возвращает id добавленной строки — по нему её потом переписывает повторная чистка
    /// (`replace(id:text:)`). `nil` — писать было нечего.
    @discardableResult
    public func add(
        _ text: String,
        language: Language,
        audio: String? = nil,
        seconds: Double? = nil
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let item = HistoryItem(text: trimmed, language: language, audio: audio, seconds: seconds)
        items.insert(item, at: 0)
        if items.count > Self.limit {
            items.removeLast(items.count - Self.limit)
        }
        save()
        return item.id
    }

    /// Диктовка, у которой распознавание не дало текста. В историю она попадает ровно затем,
    /// чтобы запись не пропала молча: текста нет, а звук есть и его можно разобрать заново.
    public func addFailed(language: Language, audio: String, seconds: Double) {
        items.insert(
            HistoryItem(text: "", language: language, audio: audio, seconds: seconds),
            at: 0
        )
        if items.count > Self.limit {
            items.removeLast(items.count - Self.limit)
        }
        save()
    }

    /// Заменяет текст записи — так возвращается результат повторного распознавания.
    public func replace(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = items[index].replacing(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        save()
    }

    /// Забывает про записи, которых на диске уже нет: кольцо коротко, а история длинная,
    /// и кнопка «распознать заново» не должна вести в никуда.
    public func forgetAudio(missing exists: (String) -> Bool) {
        var changed = false
        for (index, item) in items.enumerated() {
            guard let audio = item.audio, !exists(audio) else { continue }
            items[index] = HistoryItem(
                id: item.id,
                date: item.date,
                text: item.text,
                language: item.language,
                audio: nil,
                seconds: item.seconds
            )
            changed = true
        }
        // Пустая запись без звука — уже ни текст, ни материал: держать её незачем.
        let before = items.count
        items.removeAll { $0.text.isEmpty && $0.audio == nil }
        if changed || items.count != before { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
