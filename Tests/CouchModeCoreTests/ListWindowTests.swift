import XCTest
@testable import CouchModeCore

final class ListWindowTests: XCTestCase {
    private func start(_ count: Int, _ cap: Int) -> ListWindow { ListWindow(first: 0, count: count, capacity: cap) }

    func testShortListShowsEverythingWithNoFades() {
        let w = ListWindow.following(start(5, 10), focused: 4, count: 5, capacity: 10)
        XCTAssertEqual(w.range, 0..<5)
        XCTAssertFalse(w.hasMoreAbove); XCTAssertFalse(w.hasMoreBelow)
    }

    func testExactFitDoesNotScroll() {
        let w = ListWindow.following(start(10, 10), focused: 9, count: 10, capacity: 10)
        XCTAssertEqual(w.first, 0); XCTAssertFalse(w.hasMoreBelow)
    }

    func testNoScrollWhileFocusStaysOneRowInsideTheEdge() {
        let w = ListWindow.following(start(13, 8), focused: 6, count: 13, capacity: 8)
        XCTAssertEqual(w.first, 0); XCTAssertTrue(w.hasMoreBelow); XCTAssertFalse(w.hasMoreAbove)
    }

    func testScrollsDownKeepingOneRowOfContextBelow() {
        let w = ListWindow.following(start(13, 8), focused: 7, count: 13, capacity: 8)
        XCTAssertEqual(w.first, 1)
        XCTAssertEqual(w.range, 1..<9)
    }

    func testClampsAtTheBottom() {
        var w = start(13, 8)
        for i in 0..<13 { w = ListWindow.following(w, focused: i, count: 13, capacity: 8) }
        XCTAssertEqual(w.first, 5); XCTAssertEqual(w.range, 5..<13)
        XCTAssertTrue(w.hasMoreAbove); XCTAssertFalse(w.hasMoreBelow)
    }

    func testScrollsUpKeepingOneRowOfContextAbove() {
        let w = ListWindow.following(ListWindow(first: 5, count: 13, capacity: 8), focused: 5, count: 13, capacity: 8)
        XCTAssertEqual(w.first, 4)
    }

    func testJumpToEndAndBack() {
        let end = ListWindow.following(start(13, 8), focused: 12, count: 13, capacity: 8)
        XCTAssertEqual(end.first, 5)
        let top = ListWindow.following(end, focused: 0, count: 13, capacity: 8)
        XCTAssertEqual(top.first, 0)
    }

    func testFocusIsAlwaysVisible() {
        for cap in 1...6 {
            var w = start(15, cap)
            for i in Array(0..<15) + Array((0..<15).reversed()) {
                w = ListWindow.following(w, focused: i, count: 15, capacity: cap)
                XCTAssertTrue(w.range.contains(i), "cap \(cap) focus \(i)")
            }
        }
    }

    func testTinyCapacityHasNoMargin() {
        let w = ListWindow.following(start(5, 2), focused: 2, count: 5, capacity: 2)
        XCTAssertEqual(w.range, 1..<3)
    }

    func testCapacityShrinkingKeepsFocusVisible() {
        let w = ListWindow.following(ListWindow(first: 0, count: 13, capacity: 10), focused: 9, count: 13, capacity: 6)
        XCTAssertTrue(w.range.contains(9))
    }

    func testEmptyAndOutOfRangeFocus() {
        XCTAssertEqual(ListWindow.following(start(0, 5), focused: 3, count: 0, capacity: 5).range, 0..<0)
        XCTAssertEqual(ListWindow.following(start(13, 8), focused: 99, count: 13, capacity: 8).first, 5)
    }

    func testCapacityFromHeight() {
        XCTAssertEqual(ListWindow.capacity(height: 860, rowHeight: 86), 10)
        XCTAssertEqual(ListWindow.capacity(height: 10, rowHeight: 86), 1)
        XCTAssertEqual(ListWindow.capacity(height: 0, rowHeight: 0), 1)
    }
}
