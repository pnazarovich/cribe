import XCTest
@testable import CribeCore

/// Движок-заглушка: считает, сколько распознаваний вошло одновременно.
private final class ConcurrencyProbe: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var observedPeak = 0

    var peak: Int { lock.withLock { observedPeak } }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.ready)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        lock.withLock {
            active += 1
            observedPeak = max(observedPeak, active)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        lock.withLock { active -= 1 }
        return prompt
    }
}

final class EngineGateTests: XCTestCase {

    /// WhisperKit-инстанс не потокобезопасен: превью и финальный проход не должны
    /// пересекаться, даже если вызовы пришли одновременно (актор сам по себе реентерабелен).
    func testConcurrentCallsAreSerialized() async {
        let probe = ConcurrencyProbe()
        let gate = EngineGate(probe)

        let results = await withTaskGroup(of: String?.self) { group in
            for index in 0..<5 {
                group.addTask { try? await gate.transcribe([], language: .ru, prompt: "\(index)") }
            }
            var collected: Set<String> = []
            for await value in group {
                if let value { collected.insert(value) }
            }
            return collected
        }

        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(probe.peak, 1)
    }
}
