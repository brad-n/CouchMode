// Owns: the state of a title's details screen: what the row had, the fuller
// details once the reader sends them, focus (buttons, season tabs, episodes)
// and the reader calls it makes (details on open, a season's episodes when
// it is focused and empty). Late results are dropped once the screen is
// closed. Does not own drawing or navigation.

import Foundation
import SwiftUI
import os
import CouchModeCore

@MainActor
final class StreamDetailModel: ObservableObject {
    enum Button: Equatable { case play, openOnSite }
    /// What Select does, as a web address to hand to the service's own player or page.
    /// `open` plays a title or episode in the service's player; `page` opens the service's website.
    enum Activation: Equatable { case open(URL), page(URL), none }

    let service: Service
    let source: StreamSource
    /// The stream home this opened from (Back returns to it).
    let home: StreamHomeModel
    let rowTitle: StreamTitle
    @Published private(set) var details: StreamTitleDetails?
    @Published private(set) var focus: StreamDetailFocus
    @Published private(set) var episodesLoading = false

    private var closed = false
    private var episodesTried: Set<String> = []
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "stream")

    init(title: StreamTitle, home: StreamHomeModel) {
        rowTitle = title
        self.home = home
        source = home.source
        service = home.service
        focus = StreamDetailFocus(buttons: title.page == nil ? 1 : 2)
    }

    // MARK: Reading

    /// The row's info until the details arrive.
    var title: StreamTitle { details?.title ?? rowTitle }
    var seasons: [StreamSeason] { details?.seasons ?? [] }
    var season: StreamSeason? { seasons.indices.contains(focus.season) ? seasons[focus.season] : nil }
    var episodes: [StreamEpisode] { season?.episodes ?? [] }
    var buttons: [Button] { title.page == nil ? [.play] : [.play, .openOnSite] }
    var playLabel: String { (title.resumeSeconds ?? 0) > 0 ? "Resume" : "Play" }

    func label(for button: Button) -> String {
        switch button {
        case .play: return playLabel
        case .openOnSite: return "Open on \(service.name)"
        }
    }

    /// What Select does on the focused item.
    var activation: Activation {
        switch focus.target {
        case .button(let i):
            guard buttons.indices.contains(i) else { return .none }
            switch buttons[i] {
            case .play: return .open(title.play)
            case .openOnSite: return title.page.map { .page($0) } ?? .none
            }
        case .season: return .none
        case .episode(let i): return episodes.indices.contains(i) ? .open(episodes[i].play) : .none
        }
    }

    // MARK: Loading

    func load() {
        Task { [weak self] in
            guard let self, let read = await source.details(for: rowTitle), !closed else { return }
            apply(read.bounded)
            loadEpisodesIfNeeded()
        }
    }

    /// Stops late results from touching the screen.
    func close() { closed = true }

    private func apply(_ read: StreamTitleDetails) {
        details = read
        let current = read.currentSeasonID.flatMap { id in read.seasons.firstIndex { $0.id == id } } ?? 0
        if case .button(0) = focus.target {
            focus = StreamDetailFocus(buttons: buttons.count, seasons: read.seasons.count, episodes: 0, season: current)
        }
        resize()
    }

    private func resize() {
        focus = focus.resized(buttons: buttons.count, seasons: seasons.count, episodes: episodes.count)
    }

    func move(_ direction: Direction) {
        let before = focus.season
        focus = focus.moved(direction)
        resize()
        if focus.season != before { loadEpisodesIfNeeded() }
    }

    /// A season focused without episodes yet: asks the reader once for them.
    private func loadEpisodesIfNeeded() {
        guard let season, season.episodes.isEmpty, !episodesTried.contains(season.id) else { return }
        episodesTried.insert(season.id)
        episodesLoading = true
        Task { [weak self] in
            guard let self else { return }
            let read = await source.episodes(in: season, of: rowTitle)
            guard !closed else { return }
            if let read, var current = details, let i = current.seasons.firstIndex(where: { $0.id == season.id }) {
                current.seasons[i].episodes = Array(read.prefix(StreamLimits.maxEpisodesPerSeason))
                details = current
                resize()
            }
            episodesLoading = false
            log.info("episodes season=\(season.id, privacy: .public) got=\(read?.count ?? -1)")
        }
    }
}
