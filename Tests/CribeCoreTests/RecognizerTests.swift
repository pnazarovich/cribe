import XCTest
@testable import CribeCore

/// Развилка между Whisper и Parakeet. Проверяется без моделей на диске: всё, что здесь
/// спрашивается, движки решают до первого похода в файлы или сеть.
final class RecognizerTests: XCTestCase {
    private func recognizer() -> Recognizer {
        Recognizer(whisper: WhisperEngine(), parakeet: ParakeetEngine())
    }

    /// Выбор «точно» — это по-прежнему Whisper, только другой её вес: развилка обязана
    /// передать его самой Whisper, иначе выбор останется словом в настройках.
    func testPreciseModeSwitchesWhisperVariant() {
        let recognizer = recognizer()
        XCTAssertFalse(recognizer.whisper.prefersAccuracy)

        recognizer.mode = .precise
        XCTAssertTrue(recognizer.whisper.prefersAccuracy)
        XCTAssertEqual(recognizer.whisper.variant(for: .ru), WhisperModel.large)

        recognizer.mode = .parakeet
        XCTAssertFalse(recognizer.whisper.prefersAccuracy)
    }

    /// Parakeet сегментов с таймкодами не отдаёт — и говорит об этом, а не подсовывает
    /// пустоту: на этом ответе конвейер снимает потоковую финализацию и идёт полным проходом.
    func testParakeetReportsMissingSegments() async {
        let recognizer = recognizer()
        recognizer.mode = .parakeet
        do {
            _ = try await recognizer.transcribeSegments([], language: .ru, prompt: "")
            XCTFail("сегменты не должны появиться")
        } catch TranscriptionEngineError.segmentsUnsupported {
        } catch {
            XCTFail("ожидали segmentsUnsupported, получили \(error)")
        }
    }

    /// Перевод задачей декодера Parakeet не умеет. Молчаливый обычный проход вернул бы
    /// русский текст под видом английского — поэтому именно ошибка.
    func testParakeetRefusesTranslation() async {
        let recognizer = recognizer()
        recognizer.mode = .parakeet
        do {
            _ = try await recognizer.transcribe([], language: .ru, prompt: "", translating: true)
            XCTFail("перевод не должен получиться")
        } catch TranscriptionEngineError.translationUnsupported {
        } catch {
            XCTFail("ожидали translationUnsupported, получили \(error)")
        }
    }

    /// Названный по имени вариант — понятие Whisper (повторный разбор записи из истории),
    /// и уходить он обязан ей даже когда слушает Parakeet.
    func testNamedVariantAlwaysGoesToWhisper() async {
        let recognizer = recognizer()
        recognizer.mode = .parakeet
        do {
            _ = try await recognizer.transcribe([], language: .ru, variant: WhisperModel.large, prompt: "")
            XCTFail("непрогретая модель не должна распознавать")
        } catch TranscriptionEngineError.notPrepared {
        } catch {
            XCTFail("ожидали notPrepared от Whisper, получили \(error)")
        }
    }

    /// Живая панель работает на своей лёгкой модели, и выбор движка её не касается.
    func testPreviewAlwaysGoesToWhisper() async {
        let recognizer = recognizer()
        recognizer.mode = .parakeet
        do {
            _ = try await recognizer.transcribePreview([], language: .ru)
            XCTFail("превью без прогрева не должно распознавать")
        } catch TranscriptionEngineError.previewNotPrepared {
        } catch {
            XCTFail("ожидали previewNotPrepared, получили \(error)")
        }
    }
}
