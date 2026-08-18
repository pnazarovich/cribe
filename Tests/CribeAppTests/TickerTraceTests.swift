import XCTest
@testable import Cribe

/// Числовой след хода ленты. Не проверка, а прибор: глазами движение видит только владелец,
/// а здесь видно то же самое цифрами.
///
/// Мерить надо ровно то, что видит глаз, и первая версия этого прибора мерила не то.
/// Она печатала скорость и отставание — то есть внутренние числа регулятора, — и по ним
/// выходило, что всё ровно, тогда как на экране лента дёргалась. Отставание, упёршееся
/// в потолок, читается как «ровное», хотя означает, что каждый приход текста лента
/// перешагивает рывком. Здесь меряется другое: НА СКОЛЬКО СДВИНУЛОСЬ СЛОВО, которое
/// человек в этот момент читает.
///
/// Без `CRIBE_TICKER_TRACE` пропускается: это диагностика, а не часть прогона.
@MainActor
final class TickerTraceTests: XCTestCase {

    private func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Ровная речь: проход раз в 0,8 с приносит два слова.
    func testTraceSteadySpeech() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRIBE_TICKER_TRACE"] == nil)
        try trace(name: "ровная речь", chunkWords: 2, chunkSeconds: 0.8, chunks: 16)
    }

    /// Быстрая речь: те же проходы, но по четыре слова.
    func testTraceFastSpeech() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRIBE_TICKER_TRACE"] == nil)
        try trace(name: "быстрая речь", chunkWords: 4, chunkSeconds: 0.8, chunks: 16)
    }

    /// Медленная, с паузами: слово раз в полторы секунды.
    func testTraceSlowSpeech() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRIBE_TICKER_TRACE"] == nil)
        try trace(name: "медленная речь", chunkWords: 1, chunkSeconds: 1.5, chunks: 12)
    }

    /// Разовый большой кусок: так выглядит слепое продолжение после трёх промахов. Больше
    /// `LiveTranscript.maxTail` склейка за раз не дописывает — восемь слов и берём.
    func testTraceBlindContinuation() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRIBE_TICKER_TRACE"] == nil)
        try trace(name: "слепое продолжение", chunkWords: 2, chunkSeconds: 0.8, chunks: 12,
                  burstAt: 5, burstWords: 8)
    }

    /// Где нарисовано слово с номером `id`: отсчитываем от левого края окна по тому же,
    /// что отдаёт лента виду. Это и есть «что видит глаз».
    private func place(of id: Int, in tape: LiveTicker.Tape) -> CGFloat? {
        let viewport = tape.viewport
        guard let first = viewport.words.first, id >= first.id else { return nil }
        var x = viewport.offset
        for word in viewport.words {
            if word.id == id { return x }
            x += LiveTicker.textWidth(word.id == 0 ? word.text : " " + word.text)
        }
        return nil
    }

    private func trace(
        name: String,
        chunkWords: Int,
        chunkSeconds: TimeInterval,
        chunks: Int,
        burstAt: Int = -1,
        burstWords: Int = 0
    ) throws {
        var tape = LiveTicker.Tape()
        tape.resize(to: 203)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var count = 4

        // Склейка на каждом проходе переписывает всё перекрытие — под два десятка слов,
        // из которых в окне видно четыре-пять. Прибор обязан это воспроизводить: первая
        // его версия кормила ленту словами, которые никто никогда не правит, и потому
        // была слепа к самой частой причине дрожи. Правим по живому: доезжает заглавная,
        // доезжает запятая, чинится ослышка.
        var line: [String] = []
        func words(_ n: Int) -> [String] {
            while line.count < n { line.append("слово\(line.count + 1)") }
            let overlap = max(0, line.count - 20)
            for index in overlap..<max(overlap, line.count - 1) where index % 3 == 0 {
                if !line[index].hasSuffix(",") { line[index] = line[index] + "," }
            }
            if line.count > 8 { line[line.count - 8] = line[line.count - 8].capitalized }
            return line
        }

        tape.aim(at: words(count), now: now)
        tape.advance(to: now)

        var travels: [CGFloat] = []
        var stalls = 0
        var jumpAtArrival: CGFloat = 0
        var waited: TimeInterval = 0

        note("── \(name) ──")
        for chunk in 0..<chunks {
            // Что человек читает прямо сейчас — среднее из видимых слов.
            let watching = tape.viewport.words.dropFirst().first?.id
            let before = watching.flatMap { place(of: $0, in: tape) }

            count += chunk == burstAt ? burstWords : chunkWords
            tape.aim(at: words(count), now: now)

            // Приход текста не имеет права сдвинуть то, что человек читает. Это тот самый
            // прыжок: строка ехала анимированно, а поправка — кадром, и прочитанное
            // подскакивало на ширину нового слова.
            if let id = watching, let was = before, let is0 = place(of: id, in: tape) {
                jumpAtArrival = max(jumpAtArrival, abs(is0 - was))
            }

            let frames = Int(chunkSeconds * 60)
            var offscreen: TimeInterval = 0
            for _ in 0..<frames {
                let was = tape.shown
                now = now.addingTimeInterval(1.0 / 60)
                tape.advance(to: now)
                travels.append(tape.shown - was)
                if tape.lag > 1, tape.shown - was < 0.2 { stalls += 1 }
                if tape.lag > 0.5 { offscreen += 1.0 / 60 }
            }
            waited = max(waited, offscreen)
        }

        let settled = travels.suffix(travels.count / 2).sorted()
        let median = settled[settled.count / 2]
        let peak = settled.last ?? 0
        note(String(
            format: "  ИТОГ: прыжок при приходе %.2f pt, ход за кадр %.2f…%.2f (пик/медиана %.1f×), "
                  + "простоев %d/%d, свежее слово ждёт до %.1f с",
            jumpAtArrival, settled.first ?? 0, peak,
            median > 0 ? peak / median : 0,
            stalls, travels.count, waited
        ))
    }
}
