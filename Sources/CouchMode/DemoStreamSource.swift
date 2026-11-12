// Owns: the streaming reader used in demo mode: a StreamSource whose answers
// are the invented titles of DemoCatalog, with generated art, for any
// service. Like SampleStreamSource it never touches a website; unlike it, it
// is made to be photographed. Playback is never a source call.

import Foundation
import CouchModeCore

@MainActor
final class DemoStreamSource: StreamSource {
    let service: Service
    private var currentProfile = DemoCatalog.profiles[0].id

    init(service: Service) { self.service = service }

    func home() async -> StreamHome? { DemoCatalog.home(serviceID: service.id, currentProfileID: currentProfile) }

    func details(for title: StreamTitle) async -> StreamTitleDetails? { DemoCatalog.details(for: title, service: service.id) }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let number = Int(season.id.dropFirst()), season.id.hasPrefix("s") else { return season.episodes }
        return DemoCatalog.episodes(season: number, of: title, service: service.id)
    }

    func search(_ query: String) async -> [StreamTitle]? { DemoCatalog.search(query, service: service.id) }

    func more(in row: StreamRow) async -> [StreamTitle]? { nil }

    func switchProfile(to profileID: String) async -> Bool {
        guard DemoCatalog.profiles.contains(where: { $0.id == profileID }) else { return false }
        currentProfile = profileID
        return true
    }
}
