// Owns: the state of a service's stream home screen: its home as the reader
// last read it, where focus is, the profile picker, and the reader calls the
// screen makes (load, refresh, "more" at the end of a row, switch profile).
// Results that arrive after the screen moved on are dropped (an epoch bumps
// whenever the home is replaced). Does not own drawing or navigation.

import Foundation
import SwiftUI
import os
import CouchModeCore

@MainActor
final class StreamHomeModel: ObservableObject {
    let service: Service
    let source: StreamSource
    @Published private(set) var home: StreamHome?
    @Published private(set) var isLoading = true
    @Published private(set) var focus = StreamHomeFocus(rowLengths: [])
    /// The last column focused in each row, so a row keeps its slide when focus leaves it.
    @Published private(set) var rowColumns: [Int] = []
    /// A line to show the player, e.g. a profile that couldn't be switched.
    @Published private(set) var notice: String?
    /// The profile picker, when open: the highlighted profile.
    @Published private(set) var picker: Int?

    private var epoch = 0
    private var moreInFlight: Set<String> = []
    private var moreExhausted: Set<String> = []
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "stream")

    private enum Limits {
        static let noticeSeconds: Double = 4
    }

    /// Called with each home read, so the coordinator can keep the last one per
    /// service and show it at once next time.
    var onRead: ((StreamHome) -> Void)?

    /// Called when a profile switch lands on a page only the person can finish (with the line
    /// shown to them), so the coordinator can show the service's website. The home is not re-read
    /// here: coming back from the website re-reads it.
    var onNeedsPerson: ((String) -> Void)?

    /// `cached`: the home from the last visit, shown at once (the caller then
    /// calls refresh() to re-read it behind the screen).
    init(source: StreamSource, showing cached: StreamHome? = nil) {
        self.source = source
        service = source.service
        if let cached { apply(cached) }
    }

    // MARK: Reading

    var rows: [StreamRow] { home?.rows ?? [] }
    var target: StreamHomeTarget { focus.target }

    /// The title under focus; nil on the top bar.
    var focusedTitle: StreamTitle? {
        guard case .title(let r, let i) = focus.target, rows.indices.contains(r), rows[r].titles.indices.contains(i) else { return nil }
        return rows[r].titles[i]
    }

    var focusedRow: StreamRow? {
        guard case .title(let r, _) = focus.target, rows.indices.contains(r) else { return nil }
        return rows[r]
    }

    /// The hero: the focused title, or the service's own billboard while on the top bar.
    var heroTitle: StreamTitle? { focusedTitle ?? home?.hero ?? rows.first?.titles.first }

    /// Which column a row is slid to: the focus when it is in the row, else where it was left.
    func column(inRow r: Int) -> Int {
        if case .title(let row, let i) = focus.target, row == r { return i }
        return rowColumns.indices.contains(r) ? rowColumns[r] : 0
    }

    // MARK: Loading

    /// Reads the home. False when the reader couldn't (the caller falls back to the website).
    func load() async -> Bool {
        isLoading = true
        let mine = bump()
        guard let read = await source.home() else { return false }
        guard mine == epoch else { return true }   // replaced meanwhile: not a failure
        apply(read)
        return true
    }

    /// Re-reads the home in the background (progress changed); keeps what's shown if it can't.
    func refresh() {
        let mine = bump(clearMore: false)
        Task { [weak self] in
            guard let self, let read = await source.home(), mine == self.epoch else { return }
            self.apply(read)
        }
    }

    private func bump(clearMore: Bool = true) -> Int {
        epoch += 1
        if clearMore { moreInFlight = []; moreExhausted = [] }
        return epoch
    }

    private func apply(_ read: StreamHome) {
        let bounded = read.bounded
        onRead?(bounded)
        let oldRows = rows
        home = bounded
        isLoading = false
        focus = focus.refocused(from: oldRows, to: bounded.rows)
        rowColumns = Array(rowColumns.prefix(bounded.rows.count)) + Array(repeating: 0, count: max(0, bounded.rows.count - rowColumns.count))
        noteColumn()
        log.info("home service=\(self.service.id, privacy: .public) rows=\(bounded.rows.count)")
    }

    // MARK: Focus

    func move(_ direction: Direction) {
        focus = focus.moved(direction)
        noteColumn()
        loadMoreIfNeeded()
    }

    private func noteColumn() {
        if case .title(let r, let i) = focus.target, rowColumns.indices.contains(r) { rowColumns[r] = i }
    }

    /// Near the end of a row the service holds more of: asks for the next
    /// batch, one request per row at a time, and appends it within the cap.
    private func loadMoreIfNeeded() {
        guard case .title(let r, let i) = focus.target, rows.indices.contains(r) else { return }
        let row = rows[r]
        guard StreamFocus.needsMore(row: row, focusedIndex: i), !moreInFlight.contains(row.id),
              !moreExhausted.contains(row.id) else { return }
        moreInFlight.insert(row.id)
        let mine = epoch
        Task { [weak self] in
            guard let self else { return }
            let more = await source.more(in: row)
            guard mine == self.epoch else { return }
            self.moreInFlight.remove(row.id)
            self.append(more, to: row.id)
        }
    }

    private func append(_ more: [StreamTitle]?, to rowID: String) {
        guard var current = home, let r = current.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let known = Set(current.rows[r].titles.map(\.id))
        let fresh = (more ?? []).filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { moreExhausted.insert(rowID); return }
        current.rows[r].titles = Array((current.rows[r].titles + fresh).prefix(StreamLimits.maxTitlesPerRow))
        home = current
        focus = focus.resized(rowLengths: current.rows.map(\.titles.count))
        log.info("more row=\(rowID, privacy: .public) now=\(current.rows[r].titles.count)")
    }

    // MARK: Profiles

    func openPicker() {
        guard let profiles = home?.profiles, !profiles.isEmpty else { return }
        picker = profiles.firstIndex { $0.id == home?.currentProfileID } ?? 0
    }

    func closePicker() { picker = nil }

    func movePicker(_ direction: Direction) {
        guard let current = picker, let count = home?.profiles.count, count > 0 else { return }
        switch direction {
        case .up: picker = max(0, current - 1)
        case .down: picker = min(count - 1, current + 1)
        case .left, .right: break
        }
    }

    /// Picks the highlighted profile. A locked one isn't switchable in v1.
    func chooseProfile() {
        guard let i = picker, let profiles = home?.profiles, profiles.indices.contains(i) else { return }
        let profile = profiles[i]
        if profile.isLocked { return }
        picker = nil
        guard profile.id != home?.currentProfileID else { return }
        isLoading = true
        let mine = bump()
        Task { [weak self] in
            guard let self else { return }
            let result = await source.switchProfile(to: profile.id)
            guard mine == self.epoch else { return }
            let line = result.notice(profileName: profile.name, serviceName: self.service.name)
            if result.handsOffToWebsite, let line {
                self.isLoading = false
                self.say(line)
                self.onNeedsPerson?(line)
                return
            }
            if let line { self.say(line) }
            let read = await source.home()
            guard mine == self.epoch else { return }
            if let read { self.apply(read) } else { self.isLoading = false }
        }
    }

    private func say(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + Limits.noticeSeconds) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }
}
