import XCTest
@testable import CouchModeCore

final class StreamKeyboardTests: XCTestCase {
    private func type(_ kb: inout StreamKeyboard, _ ch: Character) {
        kb.focus(key: .character(ch))
        kb.press()
    }

    func testLayoutHasEveryKeyOnce() {
        let keys = StreamKeyboard.layout.flatMap { $0 }
        XCTAssertEqual(Set(keys).count, keys.count)
        for ch in "abcdefghijklmnopqrstuvwxyz0123456789" { XCTAssertTrue(keys.contains(.character(ch))) }
        for action in [StreamKeyboard.Key.space, .delete, .clear] { XCTAssertTrue(keys.contains(action)) }
        XCTAssertEqual(keys.count, 39)
    }

    func testStartsOnFirstKeyWithEmptyText() {
        let kb = StreamKeyboard()
        XCTAssertEqual(kb.text, "")
        XCTAssertEqual(kb.focusedKey, .character("a"))
    }

    func testEdgesStopWithoutWrapping() {
        var kb = StreamKeyboard()
        kb.move(.left); kb.move(.up)
        XCTAssertEqual(kb.focusedKey, .character("a"))
        for _ in 0..<20 { kb.move(.right) }
        XCTAssertEqual(kb.focusedKey, StreamKeyboard.layout[0].last)
        for _ in 0..<20 { kb.move(.down) }
        XCTAssertEqual(kb.focusedRow, StreamKeyboard.layout.count - 1)
        kb.move(.down)
        XCTAssertEqual(kb.focusedRow, StreamKeyboard.layout.count - 1)
    }

    func testColumnClampsIntoShorterActionRow() {
        var kb = StreamKeyboard()
        for _ in 0..<20 { kb.move(.right) }
        for _ in 0..<20 { kb.move(.down) }
        XCTAssertEqual(kb.focusedKey, StreamKeyboard.layout.last?.last)
    }

    func testPressTypesAndActions() {
        var kb = StreamKeyboard()
        type(&kb, "h"); type(&kb, "i")
        XCTAssertEqual(kb.text, "hi")
        kb.focus(key: .space); kb.press()
        type(&kb, "5")
        XCTAssertEqual(kb.text, "hi 5")
        kb.focus(key: .delete); kb.press()
        XCTAssertEqual(kb.text, "hi ")
        kb.focus(key: .clear); kb.press()
        XCTAssertEqual(kb.text, "")
        kb.focus(key: .delete); kb.press()
        XCTAssertEqual(kb.text, "")
    }

    func testSpaceNeverLeadsOrDoubles() {
        var kb = StreamKeyboard()
        kb.focus(key: .space); kb.press()
        XCTAssertEqual(kb.text, "")
        type(&kb, "a")
        kb.focus(key: .space); kb.press(); kb.press()
        XCTAssertEqual(kb.text, "a ")
    }

    func testTextIsCappedAtMaxQueryLength() {
        var kb = StreamKeyboard()
        for _ in 0..<(StreamLimits.maxQueryLength + 25) { type(&kb, "x") }
        XCTAssertEqual(kb.text.count, StreamLimits.maxQueryLength)
        kb.focus(key: .space); kb.press()
        XCTAssertEqual(kb.text.count, StreamLimits.maxQueryLength)
        kb.focus(key: .delete); kb.press()
        XCTAssertEqual(kb.text.count, StreamLimits.maxQueryLength - 1)
    }

    func testClearTextKeepsFocus() {
        var kb = StreamKeyboard()
        type(&kb, "m")
        kb.clearText()
        XCTAssertEqual(kb.text, "")
        XCTAssertEqual(kb.focusedKey, .character("m"))
    }

    func testFocusOutOfRangeIsIgnored() {
        var kb = StreamKeyboard()
        type(&kb, "q")
        XCTAssertEqual(kb.focusedKey, .character("q"))
        kb.focus(row: 99, column: 0)
        XCTAssertEqual(kb.focusedKey, .character("q"))
    }
}
