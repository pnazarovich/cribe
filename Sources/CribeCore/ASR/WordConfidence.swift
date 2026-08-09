import Foundation

/// Кусок, которым распознаватель думает: обычно часть слова, а не слово. Пробел в начале —
/// его же метка начала нового слова.
public struct TokenProbe: Equatable, Sendable {
    public let text: String
    public let probability: Float

    public init(text: String, probability: Float) {
        self.text = text
        self.probability = probability
    }
}

/// Слово и уверенность распознавания в нём.
public struct WordProbe: Equatable, Sendable {
    public let word: String
    public let probability: Float

    public init(word: String, probability: Float) {
        self.word = word
        self.probability = probability
    }
}

/// Склейка кусков в слова с уверенностью.
///
/// Уверенность слова — вероятность САМОГО СЛАБОГО из его кусков, а не средняя. Слово
/// собирается из двух-трёх кусков, и достаточно ошибиться в одном, чтобы слово вышло
/// не тем; среднее такую ошибку размывает ровно там, где её и надо видеть.
public enum WordConfidence {
    public static func words(from pieces: [TokenProbe]) -> [WordProbe] {
        var words: [WordProbe] = []
        for piece in pieces {
            let starts = piece.text.hasPrefix(" ") || words.isEmpty
            let text = piece.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if starts {
                words.append(WordProbe(word: text, probability: piece.probability))
            } else {
                let previous = words.removeLast()
                words.append(WordProbe(
                    word: previous.word + text,
                    probability: min(previous.probability, piece.probability)
                ))
            }
        }
        return words
    }
}
