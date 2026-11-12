import XCTest
@testable import CouchModeCore

final class StreamFocusTests: XCTestCase {
    private func title(_ id: Int) -> StreamTitle {
        StreamTitle(id: "t\(id)", name: "Title \(id)", kind: .movie, play: URL(string: "https://example.invalid/watch/\(id)")!)
    }

    private func row(loaded: Int, total: Int?) -> StreamRow {
        StreamRow(id: "r", title: "Row", kind: .standard, titles: (0..<loaded).map(title), totalCount: total)
    }

    // MARK: Home

    func testStartsOnTheFirstTitle() {
        XCTAssertEqual(StreamHomeFocus(rowLengths: [5, 3]).target, .title(row: 0, index: 0))
    }

    func testWithoutContentFocusIsOnTheTopBar() {
        XCTAssertEqual(StreamHomeFocus(rowLengths: []).target, .search)
        XCTAssertEqual(StreamHomeFocus(rowLengths: []).moved(.right).target, .profile)
        XCTAssertEqual(StreamHomeFocus(rowLengths: []).moved(.down).target, .search)
    }

    func testUpFromTheFirstRowReachesTheTopBarAndDownComesBackToTheSameTile() {
        let f = StreamHomeFocus(rowLengths: [5, 3]).moved(.right).moved(.right)
        let bar = f.moved(.up)
        XCTAssertEqual(bar.target, .search)
        XCTAssertEqual(bar.moved(.down).target, .title(row: 0, index: 2))
    }

    func testUpFromALaterRowStaysInContent() {
        let f = StreamHomeFocus(rowLengths: [5, 3]).moved(.down)
        XCTAssertEqual(f.moved(.up).target, .title(row: 0, index: 0))
    }

    func testTopBarMovesBetweenSearchAndProfileAndStopsAtEdges() {
        let bar = StreamHomeFocus(rowLengths: [2]).moved(.up)
        XCTAssertEqual(bar.moved(.left).target, .search)
        XCTAssertEqual(bar.moved(.right).target, .profile)
        XCTAssertEqual(bar.moved(.right).moved(.right).target, .profile)
        XCTAssertEqual(bar.moved(.up).target, .search)
        XCTAssertEqual(bar.moved(.right).moved(.down).moved(.up).target, .profile)
    }

    func testEdgesStopInsteadOfWrapping() {
        var f = StreamHomeFocus(rowLengths: [2, 2])
        f = f.moved(.left)
        XCTAssertEqual(f.target, .title(row: 0, index: 0))
        f = f.moved(.right).moved(.right).moved(.right)
        XCTAssertEqual(f.target, .title(row: 0, index: 1))
        f = f.moved(.down).moved(.down)
        XCTAssertEqual(f.target, .title(row: 1, index: 1))
    }

    func testMovingBetweenRowsClampsTheColumn() {
        let f = StreamHomeFocus(rowLengths: [6, 2]).moved(.right).moved(.right).moved(.right).moved(.down)
        XCTAssertEqual(f.target, .title(row: 1, index: 1))
    }

    func testResizedKeepsThePositionClamped() {
        let f = StreamHomeFocus(rowLengths: [6, 6]).moved(.down).moved(.right).moved(.right)
        XCTAssertEqual(f.resized(rowLengths: [6, 6, 6]).target, .title(row: 1, index: 2))
        XCTAssertEqual(f.resized(rowLengths: [6, 2]).target, .title(row: 1, index: 1))
        XCTAssertEqual(f.resized(rowLengths: [4]).target, .title(row: 0, index: 2))
    }

    func testResizedFromNoContentLandsOnTheFirstTitle() {
        XCTAssertEqual(StreamHomeFocus(rowLengths: []).resized(rowLengths: [3]).target, .title(row: 0, index: 0))
    }

    func testResizedKeepsTheTopBarWhenItHadFocus() {
        let bar = StreamHomeFocus(rowLengths: [3]).moved(.up).moved(.right)
        XCTAssertEqual(bar.resized(rowLengths: [3, 3]).target, .profile)
        XCTAssertEqual(bar.resized(rowLengths: []).target, .profile)
    }

    func testAtJumpsToARealTitleOnly() {
        let f = StreamHomeFocus(rowLengths: [3, 2])
        XCTAssertEqual(f.at(row: 1, index: 1)?.target, .title(row: 1, index: 1))
        XCTAssertNil(f.at(row: 1, index: 2))
        XCTAssertNil(f.at(row: 2, index: 0))
    }

    // MARK: More

    func testNeedsMoreWithinTheLastThreeWhenTheServiceHasMore() {
        let r = row(loaded: 12, total: 30)
        XCTAssertFalse(StreamFocus.needsMore(row: r, focusedIndex: 8))
        XCTAssertTrue(StreamFocus.needsMore(row: r, focusedIndex: 9))
        XCTAssertTrue(StreamFocus.needsMore(row: r, focusedIndex: 11))
    }

    func testNeedsMoreIsFalseWhenEverythingIsLoadedOrUnknownOrAtTheCap() {
        XCTAssertFalse(StreamFocus.needsMore(row: row(loaded: 12, total: 12), focusedIndex: 11))
        XCTAssertFalse(StreamFocus.needsMore(row: row(loaded: 12, total: nil), focusedIndex: 11))
        let capped = row(loaded: StreamLimits.maxTitlesPerRow, total: 500)
        XCTAssertFalse(StreamFocus.needsMore(row: capped, focusedIndex: StreamLimits.maxTitlesPerRow - 1))
    }

    func testNeedsMoreOnAShortRowStartsAtTheFirstTile() {
        XCTAssertTrue(StreamFocus.needsMore(row: row(loaded: 2, total: 9), focusedIndex: 0))
    }

    // MARK: Window

    func testVisibleWindowFollowsTheFocusedColumnAndIsBounded() {
        XCTAssertEqual(StreamFocus.visibleWindow(count: 40, focusedColumn: 0), 0..<(StreamFocus.tilesAhead + 1))
        let mid = StreamFocus.visibleWindow(count: 40, focusedColumn: 20)
        XCTAssertTrue(mid.contains(20))
        XCTAssertEqual(mid.lowerBound, 20 - StreamFocus.tilesBehind)
        XCTAssertEqual(StreamFocus.visibleWindow(count: 5, focusedColumn: 4), 2..<5)
        XCTAssertTrue(StreamFocus.visibleWindow(count: 0, focusedColumn: 0).isEmpty)
    }

    // MARK: Details

    func testDetailsStartOnThePlayButton() {
        XCTAssertEqual(StreamDetailFocus(buttons: 2, seasons: 2, episodes: 5).target, .button(0))
    }

    func testButtonsMoveSideToSideAndStop() {
        var f = StreamDetailFocus(buttons: 2)
        f = f.moved(.left)
        XCTAssertEqual(f.target, .button(0))
        f = f.moved(.right).moved(.right)
        XCTAssertEqual(f.target, .button(1))
    }

    func testAMovieHasNothingBelowTheButtons() {
        XCTAssertEqual(StreamDetailFocus(buttons: 2).moved(.down).target, .button(0))
    }

    func testDownGoesButtonsThenSeasonsThenEpisodes() {
        var f = StreamDetailFocus(buttons: 2, seasons: 3, episodes: 4)
        f = f.moved(.down)
        XCTAssertEqual(f.target, .season(0))
        f = f.moved(.down)
        XCTAssertEqual(f.target, .episode(0))
        f = f.moved(.down)
        XCTAssertEqual(f.target, .episode(0))
    }

    func testMovingAcrossSeasonTabsChangesTheShownSeason() {
        var f = StreamDetailFocus(buttons: 2, seasons: 3, episodes: 4).moved(.down).moved(.right)
        XCTAssertEqual(f.target, .season(1))
        XCTAssertEqual(f.season, 1)
        f = f.moved(.right).moved(.right)
        XCTAssertEqual(f.target, .season(2))
        XCTAssertEqual(f.season, 2)
    }

    func testUpFromEpisodesReturnsToTheShownSeasonTab() {
        let f = StreamDetailFocus(buttons: 2, seasons: 3, episodes: 4).moved(.down).moved(.right).moved(.down).moved(.right)
        XCTAssertEqual(f.target, .episode(1))
        XCTAssertEqual(f.moved(.up).target, .season(1))
    }

    func testSeasonWithoutEpisodesYetStaysOnTheTabs() {
        let f = StreamDetailFocus(buttons: 2, seasons: 2, episodes: 0).moved(.down)
        XCTAssertEqual(f.target, .season(0))
        XCTAssertEqual(f.moved(.down).target, .season(0))
    }

    func testEpisodesWithoutSeasonTabsAreReachableFromTheButtons() {
        let f = StreamDetailFocus(buttons: 1, seasons: 0, episodes: 3).moved(.down)
        XCTAssertEqual(f.target, .episode(0))
        XCTAssertEqual(f.moved(.up).target, .button(0))
    }

    func testUpFromTheSeasonTabsReturnsToTheButtons() {
        XCTAssertEqual(StreamDetailFocus(buttons: 2, seasons: 2, episodes: 2).moved(.down).moved(.up).target, .button(0))
    }

    func testDetailResizedClampsTheTarget() {
        let f = StreamDetailFocus(buttons: 2, seasons: 2, episodes: 5).moved(.down).moved(.down)
            .moved(.right).moved(.right).moved(.right)
        XCTAssertEqual(f.target, .episode(3))
        XCTAssertEqual(f.resized(buttons: 2, seasons: 2, episodes: 2).target, .episode(1))
        XCTAssertEqual(f.resized(buttons: 2, seasons: 2, episodes: 0).target, .season(0))
        XCTAssertEqual(f.resized(buttons: 2, seasons: 0, episodes: 0).target, .button(0))
    }

    func testDetailSeasonIsClampedToTheSeasonCount() {
        XCTAssertEqual(StreamDetailFocus(buttons: 1, seasons: 2, episodes: 1, season: 9).season, 1)
        XCTAssertEqual(StreamDetailFocus(buttons: 1, seasons: 0, episodes: 0, season: 3).season, 0)
    }

    // MARK: Facts

    func testFactsLineJoinsYearRatingAndSeasonsOrRuntime() {
        var t = title(1)
        t.year = 2021; t.rating = "TV-14"; t.seasonsLabel = "2 Seasons"; t.runtimeSeconds = 3000
        XCTAssertEqual(StreamFacts.line(for: t), "2021 · TV-14 · 2 Seasons")
        t.seasonsLabel = nil
        XCTAssertEqual(StreamFacts.line(for: t), "2021 · TV-14 · 50 min")
        XCTAssertEqual(StreamFacts.line(for: title(2)), "")
    }

    func testFactsLineEndsWithEpisodeLabelWhenKnown() {
        var t = title(1)
        t.year = 2021; t.seasonsLabel = "2 Seasons"; t.episodeLabel = "S1 · E7"
        XCTAssertEqual(StreamFacts.line(for: t), "2021 · 2 Seasons · S1 · E7")
        var bare = title(2)
        bare.episodeLabel = "S2 · E3"
        XCTAssertEqual(StreamFacts.line(for: bare), "S2 · E3")
    }

    func testRuntimeText() {
        XCTAssertEqual(StreamFacts.runtimeText(seconds: 6720), "1 h 52 min")
        XCTAssertEqual(StreamFacts.runtimeText(seconds: 7200), "2 h")
        XCTAssertEqual(StreamFacts.runtimeText(seconds: 2700), "45 min")
        XCTAssertNil(StreamFacts.runtimeText(seconds: 0))
        XCTAssertNil(StreamFacts.runtimeText(seconds: 20))
    }
}
