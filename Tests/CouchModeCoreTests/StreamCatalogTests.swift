import XCTest
@testable import CouchModeCore

final class StreamCatalogTests: XCTestCase {
    private func title(_ id: String, runtime: Int? = nil, resume: Int? = nil) -> StreamTitle {
        StreamTitle(id: id, name: "Title \(id)", kind: .movie, play: URL(string: "https://example.invalid/watch/\(id)")!,
                    runtimeSeconds: runtime, resumeSeconds: resume)
    }

    func testProgressAndTimeLeftOnlyWhenPartlyWatched() {
        let partly = title("1", runtime: 3600, resume: 1320)
        XCTAssertEqual(partly.progress ?? 0, 1320.0 / 3600.0, accuracy: 0.0001)
        XCTAssertEqual(partly.remainingText, "38 min left")
        XCTAssertNil(title("2", runtime: 3600).progress)
        XCTAssertNil(title("3", runtime: 3600, resume: 0).remainingText)
        XCTAssertNil(title("4", resume: 120).progress)
        XCTAssertNil(title("5", runtime: 3600, resume: 3600).remainingText)
    }

    func testBoundedDropsEmptyRowsAndCapsSizes() {
        let many = (0..<(StreamLimits.maxTitlesPerRow + 5)).map { title(String($0)) }
        var rows = [StreamRow(id: "empty", title: "Empty", kind: .standard, titles: [])]
        rows += (0..<(StreamLimits.maxRows + 3)).map { StreamRow(id: "r\($0)", title: "Row \($0)", kind: .standard, titles: many) }
        let home = StreamHome(serviceID: "netflix", rows: rows).bounded
        XCTAssertEqual(home.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(home.rows.first?.id, "r0")
        XCTAssertTrue(home.rows.allSatisfy { $0.titles.count == StreamLimits.maxTitlesPerRow })
    }

    func testSearchQueriesAreTidiedAndCapped() {
        XCTAssertEqual(StreamSearch.normalized("  stranger \n  things "), "stranger things")
        XCTAssertNil(StreamSearch.normalized(" \n\t "))
        XCTAssertEqual(StreamSearch.normalized(String(repeating: "a", count: 500))?.count, StreamLimits.maxQueryLength)
    }

    func testDetailsBoundedCapsSeasonsAndEpisodes() {
        let play = URL(string: "https://example.invalid/watch/1")!
        let episodes = (0..<(StreamLimits.maxEpisodesPerSeason + 2)).map { StreamEpisode(id: "e\($0)", name: "E\($0)", play: play) }
        let seasons = (0..<(StreamLimits.maxSeasons + 2)).map { StreamSeason(id: "s\($0)", name: "Season \($0)", episodes: episodes) }
        let details = StreamTitleDetails(title: title("show"), seasons: seasons + [StreamSeason(id: "empty", name: "Later")]).bounded
        XCTAssertEqual(details.seasons.count, StreamLimits.maxSeasons)
        XCTAssertTrue(details.seasons.allSatisfy { $0.episodes.count == StreamLimits.maxEpisodesPerSeason })
    }

    func testCurrentProfileIsLookedUpByID() {
        let home = StreamHome(serviceID: "netflix",
                              profiles: [StreamProfile(id: "a", name: "A"), StreamProfile(id: "b", name: "B", isKids: true)],
                              currentProfileID: "b")
        XCTAssertEqual(home.currentProfile?.name, "B")
        XCTAssertNil(StreamHome(serviceID: "netflix", currentProfileID: "zz").currentProfile)
    }
}
