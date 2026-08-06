import XCTest
@testable import Cribe

/// Порядок и состояния шагов первого запуска. Правило «что сейчас делать» видно только
/// глазами — на глаз оно и ломается: то финиш недостижим у того, кто не хочет GPT, то
/// свежеустановленному пользователю подсвечивается сразу третий шаг.
final class OnboardingStepsTests: XCTestCase {

    /// Чистая установка: первым делом микрофон, остальное ждёт.
    func testFreshInstallStartsAtMicrophone() {
        let progress = OnboardingProgress()

        XCTAssertEqual(progress.activeStep, .microphone)
        XCTAssertEqual(progress.state(of: .microphone), .active)
        for step in [OnboardingStep.accessibility, .models, .ai, .ready] {
            XCTAssertEqual(progress.state(of: step), .pending, "\(step) ждёт очереди")
        }
        XCTAssertFalse(progress.isUsable)
    }

    /// Очередь двигается ровно на один шаг за раз и в объявленном порядке.
    func testActiveStepWalksTheDeclaredOrder() {
        var progress = OnboardingProgress()
        var seen: [OnboardingStep] = []

        for _ in 0..<OnboardingStep.ordered.count {
            let step = progress.activeStep
            seen.append(step)
            switch step {
            case .microphone: progress.micGranted = true
            case .accessibility: progress.accessibilityGranted = true
            case .models: progress.modelInstalled = true
            case .ai: progress.gptAuthorized = true
            case .ready: XCTFail("финиш не должен встретиться до конца очереди")
            }
        }

        XCTAssertEqual(seen, OnboardingStep.ordered)
        XCTAssertEqual(progress.activeStep, .ready)
        XCTAssertEqual(progress.state(of: .ready), .active)
    }

    /// Выданное разрешение — это галочка, а не «сейчас идёт»: сделанный шаг сворачивается.
    func testDoneStepsShowACheckmarkNotTheSpotlight() {
        var progress = OnboardingProgress()
        progress.micGranted = true

        XCTAssertEqual(progress.state(of: .microphone), .done)
        XCTAssertEqual(progress.activeStep, .accessibility)
    }

    /// Главное правило раунда: модели финиш НЕ держат. Не скачал — первая диктовка дотянет
    /// сама, и запирать за это окно не за что.
    func testModelsDoNotBlockTheFinish() {
        XCTAssertFalse(OnboardingStep.required.contains(.models), "модели не обязательны")

        var progress = OnboardingProgress(micGranted: true, accessibilityGranted: true)
        XCTAssertTrue(progress.isUsable, "диктовать уже можно и без скачанной модели")
        XCTAssertEqual(progress.activeStep, .models, "но предложить их — предлагаем")

        progress.modelsSkipped = true
        XCTAssertEqual(progress.activeStep, .ai, "«Позже» пропускает шаг дальше")
        XCTAssertEqual(progress.state(of: .models), .pending, "пропущенное не притворяется сделанным")
        XCTAssertTrue(progress.isSettled(.models))
    }

    /// ChatGPT тоже необязателен: пропустили — финиш открыт.
    func testChatGPTIsSkippable() {
        var progress = OnboardingProgress(
            micGranted: true,
            accessibilityGranted: true,
            modelInstalled: true
        )
        XCTAssertEqual(progress.activeStep, .ai)
        XCTAssertFalse(progress.isSettled(.ai))

        progress.aiSkipped = true
        XCTAssertEqual(progress.activeStep, .ready)
        XCTAssertEqual(progress.state(of: .ai), .pending)
    }

    /// Вход в ChatGPT закрывает шаг сам, без нажатия «Пропустить».
    func testChatGPTSignInClosesTheStep() {
        let progress = OnboardingProgress(
            micGranted: true,
            accessibilityGranted: true,
            modelInstalled: true,
            gptAuthorized: true
        )

        XCTAssertEqual(progress.state(of: .ai), .done)
        XCTAssertEqual(progress.activeStep, .ready)
    }

    /// Обязательное — только то, без чего диктовки нет вообще: микрофон и Универсальный
    /// доступ. Расширение этого списка обязано быть осознанным, поэтому он под тестом.
    func testOnlyPermissionsAreRequired() {
        XCTAssertEqual(OnboardingStep.required, [.microphone, .accessibility])
        XCTAssertEqual(OnboardingStep.skippable, [.models, .ai])
        XCTAssertEqual(OnboardingStep.ordered + [.ready], OnboardingStep.allCases)

        var progress = OnboardingProgress(micGranted: true)
        XCTAssertFalse(progress.isUsable, "без Accessibility ни хоткея, ни вставки")
        progress.accessibilityGranted = true
        XCTAssertTrue(progress.isUsable)
    }

    /// Финиш — черта, а не задание: галочки у него не бывает ни при каких вводных.
    func testFinishNeverGetsACheckmark() {
        let done = OnboardingProgress(
            micGranted: true,
            accessibilityGranted: true,
            modelInstalled: true,
            gptAuthorized: true
        )

        XCTAssertFalse(done.isDone(.ready))
        XCTAssertEqual(done.state(of: .ready), .active)
    }
}
