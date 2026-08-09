import XCTest
@testable import CribeCore

/// Чтение правок человека. Весь смысл приёма — заметить, что распозналось не так, по тому,
/// что человек исправил руками. Цена ошибки несимметрична: пропущенная правка стоит одной
/// подсказки, а выдуманная — мусора в словаре, который будет портить каждую диктовку.
/// Поэтому тесты в основном про то, чего замечать НЕЛЬЗЯ.
final class EditDiffTests: XCTestCase {
    /// Ради этого случая всё и делается: приложение услышало «хероблок», человек написал
    /// «heroblock». Ни одна эвристика по виду слова такую пару не выведет.
    func testSingleWordFixIsNoticed() {
        let corrections = EditDiff.corrections(
            before: "давай поправим хероблок на главной",
            after: "давай поправим heroblock на главной",
            inserted: "давай поправим хероблок на главной"
        )
        XCTAssertEqual(corrections, [Correction(heard: "хероблок", meant: "heroblock")])
    }

    /// Человек переписал фразу целиком — это он передумал, а не приложение ослышалось.
    func testRewrittenPhraseIsIgnored() {
        let corrections = EditDiff.corrections(
            before: "давай поправим хероблок на главной",
            after: "давай лучше вообще всё переделаем",
            inserted: "давай поправим хероблок на главной"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Слово заменили на два — это тоже переписывание: какое из двух считать правкой,
    /// неизвестно, и гадать мы не будем.
    func testOneWordReplacedByTwoIsIgnored() {
        let corrections = EditDiff.corrections(
            before: "поправим хероблок сегодня",
            after: "поправим hero block сегодня",
            inserted: "поправим хероблок сегодня"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Правка в чужом тексте, который лежал в поле до нас. Мы за него не отвечаем.
    func testEditOutsideOurInsertIsIgnored() {
        let corrections = EditDiff.corrections(
            before: "старая заметка про кубер и новый текст",
            after: "старая заметка про Kubernetes и новый текст",
            inserted: "и новый текст"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Заглавная буква в начале предложения — не правка. Иначе первая же диктовка
    /// принесла бы в словарь пару «привет → Привет».
    func testCapitalisationIsNotACorrection() {
        let corrections = EditDiff.corrections(
            before: "привет как дела",
            after: "Привет как дела",
            inserted: "привет как дела"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Знаки препинания человек правит постоянно, и к словарю это отношения не имеет.
    func testPunctuationOnlyEditIsIgnored() {
        let corrections = EditDiff.corrections(
            before: "поправим хероблок сегодня",
            after: "поправим хероблок, сегодня!",
            inserted: "поправим хероблок сегодня"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Дописанный в конце текст — не правка вставленного.
    func testAppendedTextIsIgnored() {
        let corrections = EditDiff.corrections(
            before: "поправим хероблок",
            after: "поправим хероблок и ещё пару мелочей",
            inserted: "поправим хероблок"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Две разные правки в одной диктовке — обе засчитываются.
    func testTwoFixesInOneText() {
        let corrections = EditDiff.corrections(
            before: "залей на впс через гитхаб",
            after: "залей на VPS через GitHub",
            inserted: "залей на впс через гитхаб"
        )
        XCTAssertEqual(
            Set(corrections),
            [Correction(heard: "впс", meant: "VPS"), Correction(heard: "гитхаб", meant: "GitHub")]
        )
    }

    /// Слово просто удалили: замены нет, учить нечему.
    func testDeletionIsNotACorrection() {
        let corrections = EditDiff.corrections(
            before: "поправим хероблок сегодня",
            after: "поправим сегодня",
            inserted: "поправим хероблок сегодня"
        )
        XCTAssertEqual(corrections, [])
    }

    /// Поле не тронули вовсе — самый частый случай, и он обязан быть бесплатным и пустым.
    func testUntouchedTextYieldsNothing() {
        let text = "поправим хероблок сегодня"
        XCTAssertEqual(EditDiff.corrections(before: text, after: text, inserted: text), [])
    }

    /// Диктовка в большой документ: сравнение квадратично, и без потолка одна правка
    /// в конце статьи стоила бы секунд. Потолок обязан молча пропускать такой случай.
    func testHugeTextIsSkipped() {
        let huge = Array(repeating: "слово", count: EditDiff.maximumWords + 1).joined(separator: " ")
        XCTAssertEqual(EditDiff.corrections(before: huge, after: huge, inserted: "слово"), [])
    }

    // MARK: - Изменения как они есть

    /// То самое место, где правило слепо, а судья — нет. Две соседние правки сливаются
    /// в один блок «два слова на два», и разбор замен не даёт НИЧЕГО. Судье этот же случай
    /// показывается как есть — и по тексту вокруг он способен разобраться.
    func testAdjacentEditsCollapseForRulesButStayVisibleAsAChange() {
        let before = "поправим хероблок сегодня"
        let after = "поправим heroblock завтра"
        XCTAssertEqual(
            EditDiff.corrections(before: before, after: after, inserted: before), [],
            "правило замен здесь молчит"
        )
        XCTAssertEqual(
            EditDiff.changes(before: before, after: after),
            [EditBlock(removed: ["хероблок", "сегодня"], added: ["heroblock", "завтра"])]
        )
    }

    /// Дописанное и удалённое — тоже изменения: судья по ним и понимает, что человек
    /// перешёл к собственной работе.
    func testAdditionsAndDeletionsAreChangesToo() {
        XCTAssertEqual(
            EditDiff.changes(before: "поправим сегодня", after: "поправим сегодня и завтра"),
            [EditBlock(removed: [], added: ["и", "завтра"])]
        )
        XCTAssertEqual(
            EditDiff.changes(before: "поправим лишнее сегодня", after: "поправим сегодня"),
            [EditBlock(removed: ["лишнее"], added: [])]
        )
    }

    func testUntouchedTextHasNoChanges() {
        let text = "поправим хероблок сегодня"
        XCTAssertEqual(EditDiff.changes(before: text, after: text), [])
    }

    /// Потолок общий: он защищает от квадратичного сравнения, а не от конкретного вызова.
    func testHugeTextHasNoChangesEither() {
        let huge = Array(repeating: "слово", count: EditDiff.maximumWords + 1).joined(separator: " ")
        XCTAssertEqual(EditDiff.changes(before: huge, after: huge + " ещё"), [])
    }
}
