import XCTest
@testable import CribeCore

/// Рекомендации — статичная таблица: проверяем состав, порядок и усилия по режимам.
final class ModelRecommendationsTests: XCTestCase {

    func testThreeTiersInOrderForEveryMode() {
        for mode in [GPTAuthMode.apiKey, .codex] {
            let list = ModelRecommendations.list(for: mode)
            XCTAssertEqual(list.count, 3, "\(mode)")
            XCTAssertEqual(list.map(\.tier), [.speed, .balance, .quality], "\(mode)")
            XCTAssertEqual(list.map(\.id), ["speed", "balance", "quality"], "\(mode)")
        }
    }

    func testModelsPerTierAreSameInBothModes() {
        let expected = ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]
        XCTAssertEqual(ModelRecommendations.list(for: .apiKey).map(\.model), expected)
        XCTAssertEqual(ModelRecommendations.list(for: .codex).map(\.model), expected)
    }

    /// API-ключ считает деньги: reasoning выключен совсем.
    func testAPIKeyEffortsAreNone() {
        XCTAssertEqual(ModelRecommendations.list(for: .apiKey).map(\.effort), ["none", "none", "none"])
    }

    /// Codex-бэкенд ниже `low` не опускается, поэтому рекомендуем сразу минимум, который он примет.
    func testCodexEffortsAreLowAndSurviveNormalization() {
        let efforts = ModelRecommendations.list(for: .codex).map(\.effort)
        XCTAssertEqual(efforts, ["low", "low", "low"])
        for effort in efforts {
            XCTAssertEqual(GPTProtocol.normalizedEffort(effort, mode: .codex), effort)
        }
    }

    func testNotesDifferBetweenModes() {
        let api = ModelRecommendations.list(for: .apiKey).map(\.note)
        let codex = ModelRecommendations.list(for: .codex).map(\.note)
        XCTAssertNotEqual(api, codex)
        for note in api + codex {
            XCTAssertFalse(note.isEmpty)
        }
        // Стоимость упоминается только там, где платят за токены; квота — только в Codex.
        XCTAssertTrue(api.allSatisfy { $0.contains("$") })
        XCTAssertTrue(codex.allSatisfy { $0.contains("квот") })
    }

    func testTierLabels() {
        XCTAssertEqual(ModelRecommendation.Tier.speed.title, "Скорость")
        XCTAssertEqual(ModelRecommendation.Tier.balance.title, "Баланс")
        XCTAssertEqual(ModelRecommendation.Tier.quality.title, "Качество")
        XCTAssertEqual(
            [ModelRecommendation.Tier.speed, .balance, .quality].map(\.emoji),
            ["⚡", "⚖️", "💎"]
        )
    }

    func testDisclaimerMentionsBenchmarkOrigin() {
        XCTAssertTrue(ModelRecommendations.disclaimer.contains("бенчмарков"))
        XCTAssertTrue(ModelRecommendations.disclaimer.contains("2026"))
    }

    /// Рекомендации ничего не переопределяют в дефолтах конфига.
    func testDefaultsUntouched() {
        XCTAssertEqual(GPTConfig.defaultModel(for: .codex), "gpt-5.6-terra")
        XCTAssertEqual(GPTConfig.defaultModel(for: .apiKey), "gpt-5.6-luna")
        XCTAssertEqual(GPTConfig.defaultEffort, "low")
    }
}
