import XCTest
@testable import Cribe
@testable import CribeCore

/// Как едет бегущая строка. Проверяется то единственное, что можно проверить без экрана, —
/// и то единственное, что делало её то дёрганой, то обрезанной, то моргающей.
///
/// История здесь важнее обычного, потому что чинилось это пять раз и каждый раз не до конца.
/// Сначала лента ехала целым куском: приходили три-четыре слова, лента сдвигалась ВПРАВО
/// на всю их ширину и оттуда медленно возвращалась. Пока она возвращалась, свежие слова
/// стояли за правым краем рамки, а левый край текста не доезжал до полосы растворения:
/// «обрезаны два последних слова» и «нет размытия» оказались одной бедой. Потом слова
/// открывались по одному — стало честнее, но осталось шагами. Потом ход сделали непрерывным,
/// и вылезло моргание: слова опознавались по месту в окне, а окно съезжает.
///
/// И только замер показал главное: положение ленты считалось ОТ КОНЦА строки, и потому
/// каждое дописанное слово обязано было двинуть строку и ровно на столько же поправить
/// отставание. Два движения, гасящих друг друга на бумаге и не гасящих на экране: ширину
/// SwiftUI менял за треть секунды, отставание — кадром. Теперь положение считается
/// от начала строки, и почти все тесты ниже — про то, что дописанное НЕ ДВИГАЕТ показанное.
@MainActor
final class LiveTickerTests: XCTestCase {

    /// Окно шириной с настоящее: у ленты в капсуле около двухсот точек.
    private func tape(_ text: String) -> LiveTicker.Tape {
        var tape = LiveTicker.Tape()
        tape.resize(to: 200)
        tape.aim(at: text.split(separator: " ").map(String.init))
        return tape
    }

    private func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    /// Длинная строка: заведомо шире окна, иначе ленте некуда ехать и проверять нечего.
    private var long: String { "зайди по SSH на VPS и проверь webhooks" }

    /// Где НАРИСОВАНО слово с этим номером — отсчитывая от левого края окна ровно так же,
    /// как это делает вид. Проверять надо это, а не внутреннюю координату ленты: держать
    /// на месте надо картинку, а не число.
    private func place(of id: Int, in tape: LiveTicker.Tape) -> CGFloat? {
        let viewport = tape.viewport
        var x = viewport.offset
        for word in viewport.words {
            if word.id == id { return x }
            x += LiveTicker.textWidth(word.id == 0 ? word.text : " " + word.text)
        }
        return nil
    }

    /// Первая строка приезжает без отставания: пустая капсула там, где человек уже говорит,
    /// хуже любого движения.
    func testFirstLineArrivesInPlace() {
        let tape = tape("проверь webhooks и nginx")
        XCTAssertEqual(tape.text, "проверь webhooks и nginx")
        XCTAssertEqual(tape.lag, 0)
        XCTAssertTrue(tape.isSettled)
    }

    /// ГЛАВНЫЙ инвариант всего устройства: дописанное слово не двигает уже показанные
    /// ни на точку. Ни положение ленты, ни то, где нарисовано первое видимое слово.
    ///
    /// Раньше двигало — и не потому, что так было задумано, а потому, что задуманное
    /// взаимное погашение расцеплялось анимацией. Здесь гасить нечего: `shown` просто
    /// не меняется.
    func testAppendingDoesNotMoveWhatIsAlreadyShown() {
        var tape = tape(long)
        let place = tape.shown
        let before = tape.viewport

        tape.aim(at: words(long + " и nginx"))

        XCTAssertEqual(tape.shown, place, "лента не сдвинулась")
        XCTAssertEqual(tape.viewport.offset, before.offset, accuracy: 0.01, "и нарисована там же")
        XCTAssertEqual(tape.viewport.words.first?.id, before.words.first?.id)
    }

    /// Дописанное растит расхождение ровно на свою ширину — и это единственное, что оно
    /// делает. Именно на этот запас лента и поедет.
    func testAppendedWordsGrowTheLagByTheirWidth() {
        var tape = tape(long)
        let before = tape.lag
        tape.aim(at: words(long + " и nginx"))

        XCTAssertEqual(tape.lag - before, LiveTicker.textWidth(" и nginx"), accuracy: 0.5)
        XCTAssertFalse(tape.isSettled)
    }

    /// Правка ЗАКАДРОВОГО слова не двигает нарисованное ни на точку — и это второй
    /// главный инвариант, наравне с дописком.
    ///
    /// Случай не редкий, а самый частый: склейка на каждом сошедшемся проходе переписывает
    /// всё перекрытие — под два десятка слов, — а в окне их видно четыре-пять. Достаточно
    /// доехавшей запятой или заглавной, чтобы все границы за ней сдвинулись, и если лента
    /// стоит на абсолютной координате, весь видимый текст телепортируется на ту же разницу.
    /// На настоящей записи так дёргалось две трети приходов, а прежний тест этого не ловил:
    /// он проверял внутреннюю координату `shown` вместо нарисованного.
    func testOffScreenCorrectionDoesNotMoveWhatIsShown() {
        var line = (1...30).map { "слово\($0)" }
        var tape = LiveTicker.Tape()
        tape.resize(to: 200)
        tape.aim(at: line)

        let watching = try? XCTUnwrap(tape.viewport.words.dropFirst().first?.id)
        let id = try! XCTUnwrap(watching)
        let before = place(of: id, in: tape)

        // Слово номер три давно уехало за левый край: к нему доехала заглавная и запятая.
        line[2] = "Слово3,"
        tape.aim(at: line)

        XCTAssertEqual(place(of: id, in: tape) ?? .nan, before ?? .nan, accuracy: 0.01,
                       "закадровая правка не имеет права двигать нарисованное")
    }

    /// А правка ВИДИМОГО слова ленту с места не сдвигает: двигается только сам текст
    /// правее него, и это движение анимируется.
    func testOnScreenCorrectionKeepsTheTapeInPlace() {
        var tape = tape(long)
        let offset = tape.viewport.offset
        let first = tape.viewport.words.first?.id

        var line = words(long)
        line[line.count - 1] = "webhooks,"
        tape.aim(at: line)

        XCTAssertEqual(tape.viewport.offset, offset, accuracy: 0.01)
        XCTAssertEqual(tape.viewport.words.first?.id, first)
    }

    /// Правка бывает и короче прежнего написания. Тогда конец текста уезжает влево и может
    /// оказаться позади ленты — а там `viewport` не находит ни одного слова и отдаёт пустоту,
    /// при том что `isSettled` рапортует «доехала». Капсула гасла посреди речи.
    func testShorteningCorrectionDoesNotStrandTheTape() {
        var tape = tape("зайди по эсэсэйч на впээс и проверь вебхуки")
        tape.aim(at: words("зайди по SSH на VPS и проверь"))

        XCTAssertFalse(tape.viewport.words.isEmpty, "строка не имеет права пропасть")
        XCTAssertEqual(tape.lag, 0, accuracy: 0.5)
        XCTAssertEqual(tape.text, "зайди по SSH на VPS и проверь")
    }

    /// Строка короче окна стоит у ПРАВОГО края — там же, где стоит конец длинной строки,
    /// и въезжает в окно тем же ходом.
    ///
    /// Ноль на месте конца текста был не защитой, а бедой: при выравнивании по левому краю
    /// короткая строка вставала в x = 0, то есть прямо в полосу растворения, и её начало
    /// показывалось полупрозрачным и размытым — хотя слева от неё ничего не уезжало.
    func testShortLineSitsAtTheRightEdge() {
        var tape = LiveTicker.Tape()
        tape.resize(to: 200)
        tape.aim(at: words("раз два три"))

        let width = LiveTicker.textWidth("раз два три")
        XCTAssertLessThan(width, 200, "строка и правда короче окна")
        XCTAssertEqual(tape.viewport.offset, 200 - width, accuracy: 1, "стоит у правого края")
        XCTAssertEqual(tape.lag, 0)
    }

    /// Правку анимируем, дописку — ни в коем случае. Счётчик правок и отличает одно
    /// от другого: на нём висит анимация ширины.
    ///
    /// Если повесить её на состав слов, анимироваться начнёт ещё и выезд слова за левый
    /// край, а там строка теряет ширину слова ровно тогда, когда сдвиг на неё же
    /// подскакивает. Эти двое обязаны гасить друг друга в одном кадре — анимировать
    /// одного из них значит их расцепить.
    func testOnlyCorrectionsCountAsRevisions() {
        var tape = tape(long)
        let before = tape.revision

        tape.aim(at: words(long + " и nginx"))
        XCTAssertEqual(tape.revision, before, "дописка — не правка")

        tape.aim(at: words(long.replacingOccurrences(of: "SSH", with: "эсэсэйч") + " и nginx"))
        XCTAssertEqual(tape.revision, before + 1, "а вот переписанное слово — правка")
    }

    /// Слова опознаются по номеру в СТРОКЕ. Дописанное не трогает опознание показанных —
    /// иначе SwiftUI считает, что изменилась вся строка, и растворяет её целиком.
    func testAppendedWordDoesNotReshuffleTheShownOnes() {
        var tape = tape(long)
        let before = tape.viewport.words
        tape.aim(at: words(long + " и nginx"))
        let after = tape.viewport.words

        XCTAssertEqual(after.map(\.id), before.map(\.id), "те же номера")
        XCTAssertEqual(after.map(\.text), before.map(\.text), "и тот же текст — растворяться нечему")
    }

    /// Правка меняет ТЕКСТ под тем же номером — это и делает её правкой одного слова,
    /// а не подменой строки.
    func testCorrectedWordKeepsItsIdentity() {
        var tape = tape("зайди по эсэсэйч на впс")
        let before = tape.viewport.words
        tape.aim(at: words("зайди по SSH на VPS"))
        let after = tape.viewport.words

        XCTAssertEqual(after.map(\.id), before.map(\.id), "номера те же")
        XCTAssertNotEqual(after.map(\.text), before.map(\.text), "а написание — нет")
    }

    /// В окно попадает только то, что в него влезает: остальное за краями, и рисовать
    /// его незачем.
    func testViewportHoldsOnlyWhatFitsTheWindow() {
        let tape = tape((1...40).map { "слово\($0)" }.joined(separator: " "))
        let shown = tape.viewport.words

        XCTAssertLessThan(shown.count, 8, "сорок слов в двести точек не помещаются")
        XCTAssertEqual(shown.last?.id, 39, "и показывается именно хвост")
        XCTAssertLessThanOrEqual(tape.viewport.offset, 0, "первое видимое начинается левее окна")
    }

    /// Лента идёт со скоростью РЕЧИ, а не выедает расхождение до нуля и замирает.
    /// Прежнее устройство считало скорость только от расхождения: лента разбирала пришедший
    /// кусок за полсекунды и стояла остаток — движение выходило пачками раз в секунду.
    func testTapeKeepsMovingBetweenChunks() {
        var tape = tape("раз")
        var now = Date()
        tape.advance(to: now)
        var count = 1

        for chunk in 0..<4 {
            count += 3
            tape.aim(at: (1...count).map { "слово\($0)" }, now: now)
            let before = tape.shown
            for _ in 0..<48 {
                now = now.addingTimeInterval(1.0 / 60)
                tape.advance(to: now)
            }
            if chunk == 3 {
                XCTAssertGreaterThan(tape.shown - before, LiveTicker.textWidth(" слово") * 0.5,
                                     "за паузу между кусками лента обязана проехать заметно")
            }
        }
    }

    /// Лента трогается с места и на МЕДЛЕННОЙ речи. Порог неподвижности стоял на скорости
    /// и обнулял её каждым кадром, не прошедшим порог, — при том что за кадр фильтр поднимает
    /// скорость лишь до доли от желаемой. Выходило, что лента не ехала вовсе, пока речь
    /// медленнее полутора слов в секунду, и порог этот зависел от частоты кадров.
    func testSlowSpeechStillMovesTheTape() {
        var tape = tape("раз два три четыре пять шесть")
        var now = Date()
        tape.advance(to: now)
        var count = 6

        for _ in 0..<4 {
            count += 1
            tape.aim(at: (1...count).map { "слово\($0)" }, now: now)
            for _ in 0..<90 {
                now = now.addingTimeInterval(1.0 / 60)
                tape.advance(to: now)
            }
        }
        XCTAssertGreaterThan(tape.shown, 0, "на слове раз в полторы секунды лента всё равно едет")
    }

    /// Конец речи лента доезжает ХОДОМ, а не перешагивает остаток одним кадром.
    /// Перешагивание тут было: остаток расхождения обнулялся, как только замеренный темп
    /// падал ниже порога, — до двух сотен точек за кадр через несколько секунд после
    /// последнего слова. Это и есть «вся строка вдруг проехала мимо».
    func testTapeCoastsToTheEndWithoutTeleporting() {
        var tape = tape("раз")
        var now = Date()
        tape.advance(to: now)
        var count = 1
        for _ in 0..<4 {
            count += 3
            tape.aim(at: (1...count).map { "слово\($0)" }, now: now)
            for _ in 0..<66 {
                now = now.addingTimeInterval(1.0 / 60)
                tape.advance(to: now)
            }
        }

        var biggest: CGFloat = 0
        for _ in 0..<900 {
            let before = tape.shown
            now = now.addingTimeInterval(1.0 / 60)
            tape.advance(to: now)
            biggest = max(biggest, tape.shown - before)
        }
        XCTAssertEqual(tape.lag, 0, accuracy: 0.5, "за пятнадцать секунд молчания доехала")
        XCTAssertLessThan(biggest, 12, "и ни один кадр не был прыжком: \(biggest) pt")
    }

    /// Пока человек говорит, лента держит небольшой запас и потому не упирается в конец
    /// текста. Замолчал — запас тает вместе с темпом, и последнее слово встаёт у края.
    func testBufferExistsOnlyWhileSpeaking() {
        var tape = tape("раз")
        var now = Date()
        tape.advance(to: now)
        var count = 1
        for _ in 0..<3 {
            count += 4
            tape.aim(at: (1...count).map { "слово\($0)" }, now: now)
            for _ in 0..<48 {
                now = now.addingTimeInterval(1.0 / 60)
                tape.advance(to: now)
            }
        }
        XCTAssertGreaterThan(tape.buffer, 0, "на речи запас есть")

        for _ in 0..<600 {
            now = now.addingTimeInterval(1.0 / 60)
            tape.advance(to: now)
        }
        XCTAssertEqual(tape.buffer, 0, accuracy: 1, "в тишине запаса нет")
        XCTAssertEqual(tape.lag, 0, accuracy: 0.5, "и лента стоит вплотную к концу текста")
    }

    /// Темп забывается сам собой: иначе лента после молчания рванула бы с прежней скоростью.
    func testRateFadesInSilence() {
        var tape = tape("раз")
        var now = Date()
        tape.advance(to: now)
        tape.aim(at: (1...9).map { "слово\($0)" }, now: now)
        now = now.addingTimeInterval(1)
        tape.aim(at: (1...17).map { "слово\($0)" }, now: now)
        tape.advance(to: now)
        let speaking = tape.rate
        XCTAssertGreaterThan(speaking, 0)

        for _ in 0..<600 {
            now = now.addingTimeInterval(1.0 / 60)
            tape.advance(to: now)
        }
        XCTAssertLessThan(tape.rate, speaking * 0.1, "за десять секунд молчания темп сходит на нет")
    }

    /// Промежуток между приходами лента МЕРЯЕТ: он складывается из паузы цикла и
    /// длительности самого прохода распознавания, а та зависит от машины.
    func testArrivalPeriodIsMeasured() {
        var tape = tape("раз два три четыре")
        var now = Date()
        for step in 1...8 {
            now = now.addingTimeInterval(1.4)
            tape.aim(at: (1...(4 + step * 2)).map { "слово\($0)" }, now: now)
        }
        XCTAssertEqual(tape.period, 1.4, accuracy: 0.15)
    }

    /// Кадр после долгого простоя не считается кадром: между записями проходят минуты,
    /// и приняв это за шаг времени, лента прыгнула бы на месте.
    func testStaleFrameDoesNotMoveTheTape() {
        var tape = tape(long)
        tape.aim(at: words(long + " и nginx"))
        let place = tape.shown

        tape.advance(to: Date())
        tape.advance(to: Date().addingTimeInterval(300))
        XCTAssertEqual(tape.shown, place, accuracy: 0.01)
    }

    /// Окно сменило ширину — расхождение сохраняется. Иначе лента прыгнула бы на разницу:
    /// капсула меняет ширину анимированно, и каждый её кадр дёргал бы текст.
    func testResizeKeepsTheLag() {
        var tape = tape((1...20).map { "слово\($0)" }.joined(separator: " "))
        tape.aim(at: (1...24).map { "слово\($0)" })
        let lag = tape.lag
        XCTAssertGreaterThan(lag, 0)

        tape.resize(to: 260)
        XCTAssertEqual(tape.lag, lag, accuracy: 0.01)
    }

    /// Ширину меряем шрифтом ленты: по ней и считается всё положение.
    func testWordWidthIsMeasuredWithTheTapeFont() {
        XCTAssertGreaterThan(LiveTicker.textWidth("Vercel"), LiveTicker.textWidth("и"))
        XCTAssertEqual(LiveTicker.textWidth(""), 0)
    }
}
