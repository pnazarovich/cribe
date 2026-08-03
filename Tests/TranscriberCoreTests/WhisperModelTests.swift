import XCTest
@testable import TranscriberCore

/// Выбор модели Whisper для сессии — единственная точка, где «смешанная речь» меняет ASR.
final class WhisperModelTests: XCTestCase {

    /// Обычный русский идёт на turbo: он быстрее, а украинских слов в диктовке не ждут.
    func testRussianDefaultsToTurbo() {
        XCTAssertEqual(
            WhisperModel.name(for: .ru, mixedSpeech: false),
            "openai_whisper-large-v3-v20240930_turbo"
        )
    }

    /// Смешанная речь уводит русский на большую модель: turbo заметно слабее на украинском.
    func testMixedSpeechMovesRussianToLarge() {
        XCTAssertEqual(WhisperModel.name(for: .ru, mixedSpeech: true), WhisperModel.large)
    }

    /// Украинский и без того обслуживает большая модель — тумблер его не касается.
    func testUkrainianAlwaysLarge() {
        XCTAssertEqual(WhisperModel.name(for: .uk, mixedSpeech: false), WhisperModel.large)
        XCTAssertEqual(WhisperModel.name(for: .uk, mixedSpeech: true), WhisperModel.large)
    }

    /// Прежний API языка не сломан: он остаётся дефолтом выбора.
    func testLanguageWhisperModelUnchanged() {
        XCTAssertEqual(Language.ru.whisperModel, WhisperModel.name(for: .ru, mixedSpeech: false))
        XCTAssertEqual(Language.uk.whisperModel, WhisperModel.large)
    }
}
