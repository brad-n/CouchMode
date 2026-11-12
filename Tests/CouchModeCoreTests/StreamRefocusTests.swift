import XCTest
@testable import CouchModeCore

final class StreamRefocusTests: XCTestCase {
    private func row(_ id: String, _ ids: [String]) -> StreamRow {
        StreamRow(id: id, title: id, kind: .standard,
                  titles: ids.map { StreamTitle(id: $0, name: $0, kind: .movie, play: URL(string: "https://example.invalid/watch/\($0)")!) },
                  totalCount: nil)
    }

    private func focus(_ rows: [StreamRow], row: Int, index: Int) -> StreamHomeFocus {
        StreamHomeFocus(rowLengths: rows.map(\.titles.count)).at(row: row, index: index)!
    }

    func testFollowsTheTitleWhenItMovedToTheFront() {
        let old = [row("cw", ["a", "b", "c"]), row("x", ["p", "q"])]
        let new = [row("cw", ["b", "a", "c"]), row("x", ["p", "q"])]
        XCTAssertEqual(focus(old, row: 0, index: 1).refocused(from: old, to: new).target, .title(row: 0, index: 0))
    }

    func testFallsBackToTheOldPositionWhenTheTitleIsGone() {
        let old = [row("cw", ["a", "b", "c"])]
        let new = [row("cw", ["x", "y"])]
        XCTAssertEqual(focus(old, row: 0, index: 2).refocused(from: old, to: new).target, .title(row: 0, index: 1))
    }

    func testSameTitleIdInAnotherRowIsNotTheSameTitle() {
        let old = [row("cw", ["a", "b"]), row("x", ["a"])]
        let new = [row("cw", ["b"]), row("x", ["a"])]
        XCTAssertEqual(focus(old, row: 0, index: 0).refocused(from: old, to: new).target, .title(row: 0, index: 0))
    }

    func testFollowsARowThatMoved() {
        let old = [row("r1", ["a"]), row("r2", ["b", "c"])]
        let new = [row("r2", ["b", "c"]), row("r1", ["a"])]
        XCTAssertEqual(focus(old, row: 1, index: 1).refocused(from: old, to: new).target, .title(row: 0, index: 1))
    }

    func testTopBarKeepsFocus() {
        let old = [row("cw", ["a"])]
        let f = focus(old, row: 0, index: 0).moved(.up)
        XCTAssertEqual(f.refocused(from: old, to: old).target, .search)
    }
}
