import XCTest
@testable import CribeCore

/// Склейка проходов бегущей строки.
///
/// Проверяется здесь ровно то, на что жаловался владелец: «показывается рывками». Рывок —
/// это когда показанное слово меняется под взглядом или строка укорачивается, поэтому почти
/// каждый тест ниже утверждает не «получилось красиво», а «не изменилось то, что человек
/// уже прочитал».
final class LiveTranscriptTests: XCTestCase {

    private func transcript(_ passes: String...) -> LiveTranscript {
        var live = LiveTranscript()
        for pass in passes { live.absorb(pass) }
        return live
    }

    /// Сдвиг окна дописывает только новый хвост — без потерь и без повторов.
    func testSlidingWindowAppendsOnlyTheNewTail() {
        let live = transcript(
            "Проверь webhooks и nginx потом",
            "webhooks и nginx потом задеплой на"
        )
        XCTAssertEqual(live.text, "Проверь webhooks и nginx потом задеплой на")
    }

    /// Последнее слово почти всегда обрублено правым краем окна. Оно — единственное,
    /// которому свежий проход вправе переписать написание.
    func testChoppedLastWordIsReplacedByTheFullOne() {
        let live = transcript(
            "надо задеплой на верс",
            "задеплой на Vercel сейчас"
        )
        XCTAssertEqual(live.text, "надо задеплой на Vercel сейчас")
    }

    /// Якорь не замечает разницы в пунктуации и заглавных, а вот сама строка её принимает:
    /// следующий проход слышит те же слова с бо́льшим контекстом справа и потому слышит их
    /// лучше. Запятая доезжает до слова, которое уже проехало полстроки.
    func testFreshPassRefinesAlreadyShownWords() {
        let live = transcript(
            "всё готово можно ехать",
            "Всё готово, можно ехать дальше"
        )
        XCTAssertEqual(live.text, "Всё готово, можно ехать дальше")
    }

    /// Правка меняет написание, но не состав и не порядок: иначе лента поехала бы назад.
    func testRefinementKeepsWordCountAndOrder() {
        var live = transcript("зайди по эсэсэйч на впс")
        let before = live.wordCount
        live.absorb("зайди по SSH на VPS")


        XCTAssertEqual(live.wordCount, before)
        XCTAssertEqual(live.text, "зайди по SSH на VPS")
    }

    /// Ослышка чинится сама собой, когда следующий проход слышит фразу целиком.
    func testMisheardWordIsCorrectedInPlace() {
        let live = transcript(
            "надо открыть прокид в постхоге и сравнить",
            "надо открыть Parakeet в PostHoge и сравнить данные"
        )
        XCTAssertEqual(live.text, "надо открыть Parakeet в PostHoge и сравнить данные")
    }

    /// Сойтись — не значит совпасть дословно. Правится ровно то, по чему выравниваемся,
    /// и раньше склейка на этом объявляла «не сошлось»: выравнивание искало точный якорь
    /// из нескольких слов подряд.
    func testJoinToleratesRewrittenWords() {
        let shown = ["зайди", "по", "эсэсэйч", "на", "впс", "и", "проверь"]
        let fresh = ["зайди", "по", "SSH", "на", "VPS", "и", "проверь", "логи"]
        XCTAssertEqual(LiveTranscript.join(shown: shown, fresh: fresh), 7)
    }

    /// Но и всё подряд склеивать нельзя: две трети совпадения — это порог, ниже которого
    /// куски считаются разными местами речи.
    func testJoinRefusesTooDifferentPieces() {
        let shown = ["раз", "два", "три", "четыре", "пять"]
        let fresh = ["совсем", "другие", "слова", "тут", "стоят"]
        XCTAssertNil(LiveTranscript.join(shown: shown, fresh: fresh))
    }

    /// Человек молчит — проход приходит тот же самый. Строка обязана остаться неподвижной:
    /// любое движение здесь было бы движением, которого не было в речи.
    func testRepeatedPassChangesNothing() {
        var live = transcript("проверь webhooks и nginx")
        let before = live.text
        live.absorb("проверь webhooks и nginx")
        XCTAssertEqual(live.text, before)
        XCTAssertEqual(live.wordCount, 4)
    }

    /// Пустой проход (в окно попала одна тишина) строку НЕ гасит. Это регресс на самый
    /// заметный рывок из всех: капсула меняла строку на волну и через 0,9 с возвращала обратно.
    func testEmptyPassDoesNotClearTheLine() {
        var live = transcript("проверь webhooks и nginx")
        live.absorb("")
        live.absorb("   ")
        XCTAssertEqual(live.text, "проверь webhooks и nginx")
    }

    /// Якорь дальше `maxTail` от конца прохода не принимается. Иначе склейка вписывала бы
    /// второй раз всё, что человек сказал за прошедшие одиннадцать секунд.
    func testJoinLeavingTooLongATailIsRejected() {
        var live = transcript("зайди по SSH на VPS проверь")
        // За период человек столько сказать не успевает: стык, оставляющий такой хвост,
        // сел не туда, и дописать его значило бы повторить сказанное второй раз.
        live.absorb("зайди по SSH на VPS проверь " + (1...12).map { "слово\($0)" }.joined(separator: " "))
        XCTAssertEqual(live.text, "зайди по SSH на VPS проверь")
    }

    /// Односложный якорь садится на чужое вхождение и крадёт всё, что между ними, — поэтому
    /// ниже двух слов якорь не опускается.
    func testShortAnchorDoesNotSwallowWords() {
        var live = transcript("задеплой на")
        live.absorb("задеплой на Vercel и потом на сервер")
        // Правильно — дописать «Vercel и потом на сервер». Неправильно (и невозможно
        // с двухсловным якорем) — сесть на второе «на» и потерять «Vercel и потом».
        XCTAssertEqual(live.text, "задеплой на Vercel и потом на сервер")
    }

    /// Долгая пауза: в окне не осталось ни одного показанного слова. Это продолжение речи,
    /// а не сбой, и оно ДОПИСЫВАЕТСЯ. Иначе строка замирала на два прохода, третьим
    /// подменялась целиком, и прочитанное отъезжало назад — ровно на это и жаловались.
    func testSpeechAfterALongPauseIsAppendedNotSwapped() {
        var live = transcript("проверь webhooks и nginx")
        live.absorb("теперь совсем про другое дело")
        XCTAssertEqual(live.text, "проверь webhooks и nginx теперь совсем про другое дело")
    }

    /// Проход, который частично перекрывается с показанным, но якорем не сошёлся, —
    /// подозрительный: дописать его целиком значило бы повторить сказанное. Строка замирает,
    /// а с третьего такого прохода подряд ПРОДОЛЖАЕТСЯ — с обрезанным началом, но никогда
    /// не подменяется. Строка обязана только расти: подмена читается как откат назад.
    func testPartiallyOverlappingMismatchFreezesThenContinues() {
        var live = transcript("проверь webhooks и nginx")
        live.absorb("nginx совершенно другая фраза целиком")
        XCTAssertEqual(live.text, "проверь webhooks и nginx", "первый промах строку не трогает")
        live.absorb("nginx и ещё одна другая фраза")
        XCTAssertEqual(live.text, "проверь webhooks и nginx", "второй тоже")
        live.absorb("nginx теперь совсем про другое")
        XCTAssertTrue(
            live.text.hasPrefix("проверь webhooks и nginx"),
            "начало строки не имеет права пропасть: \(live.text)"
        )
        XCTAssertTrue(live.text.hasSuffix("теперь совсем про другое"), live.text)
    }

    /// Совпавший кусок при этом не удваивается: «nginx» стоял в конце показанного и в начале
    /// свежего прохода — в строке он остаётся один.
    func testBlindContinuationTrimsTheOverlappingHead() {
        XCTAssertEqual(LiveTranscript.overlap(shown: ["и", "nginx"], fresh: ["nginx", "потом"]), 1)
        XCTAssertEqual(LiveTranscript.overlap(shown: ["и", "nginx"], fresh: ["и", "nginx", "потом"]), 2)
        XCTAssertEqual(LiveTranscript.overlap(shown: ["и", "nginx"], fresh: ["совсем", "другое"]), 0)
    }

    /// Последнее слово прохода стоит на границе окна, и модель заканчивает на нём фразу
    /// точкой или вопросом. Через проход оказывается, что человек просто говорил дальше —
    /// но слово уже показано. Так в строке и появлялась точка через каждые три-четыре слова.
    func testWindowEdgePunctuationIsNotKept() {
        let live = transcript(
            "ну выглядит.",
            "ну выглядит ужасно, если честно?",
            "выглядит ужасно, если честно я сейчас"
        )
        XCTAssertEqual(live.text, "ну выглядит ужасно, если честно я сейчас")
    }

    /// Запятую не трогаем: она стоит внутри фразы, границей окна не выдумывается и
    /// без неё текст читается хуже.
    func testCommasSurvive() {
        XCTAssertNil(LiveTranscript.withoutSentenceEnd("честно,"))
        XCTAssertEqual(LiveTranscript.withoutSentenceEnd("честно."), "честно")
        XCTAssertEqual(LiveTranscript.withoutSentenceEnd("правда?!"), "правда")
        XCTAssertNil(LiveTranscript.withoutSentenceEnd("готово"), "снимать нечего")
        XCTAssertNil(LiveTranscript.withoutSentenceEnd("..."), "от слова ничего не осталось бы")
    }

    /// Строка не обрезается слева ни на каком размере. Обрезка тут была и молча ломала ход
    /// ленты: та считает путь по приросту числа слов, а когда слева отрезали столько же,
    /// сколько дописали справа, прирост выходил нулевым — лента стояла, а текст менялся
    /// кадром. Случалось это ровно на быстрой речи и выглядело как прыжок.
    func testLineIsNeverTrimmedFromTheLeft() {
        var live = LiveTranscript()
        live.absorb((1...20).map { "слово\($0)" }.joined(separator: " "))
        live.absorb((15...26).map { "слово\($0)" }.joined(separator: " "))

        XCTAssertEqual(live.wordCount, 26)
        XCTAssertTrue(live.text.hasPrefix("слово1 "), live.text)
        XCTAssertTrue(live.text.hasSuffix("слово25 слово26"), live.text)
    }

    /// «ё» и «е» модель ставит как придётся — якорь на этом рваться не должен.
    func testYoAndYeAreTheSameWordForTheAnchor() {
        let live = transcript("надо ещё раз проверить", "надо еще раз проверить всё")
        XCTAssertEqual(live.text, "надо еще раз проверить всё")
    }

    /// Первые проходы короче якоря: каждый следующий просто уточняет предыдущий, и склейка
    /// обязана принимать их, а не считать «не сошлось». Иначе три коротких прохода подряд
    /// объявляли строку протухшей и начало фразы пропадало.
    func testShortBeginningIsRefinedNotDiscarded() {
        let live = transcript("проверь", "проверь webhooks", "проверь webhooks и nginx")
        XCTAssertEqual(live.text, "проверь webhooks и nginx")
    }
}