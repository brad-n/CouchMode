// Owns: a service's stream home screen: the focused title as the hero over
// its art, a top bar (Search, profile chip, clock), rows of 16:9 tiles that
// slide so the focused tile is always on screen, and the profile picker.
// State and reader calls are StreamHomeModel's; input is the coordinator's.

import SwiftUI
import CouchModeCore

struct StreamHomeView: View {
    @ObservedObject var model: StreamHomeModel

    private enum Metrics {
        static let heroHeight: CGFloat = 330
        static let rowTitleGap: CGFloat = 14
        static let rowGap: CGFloat = 26
        static let tileInset: CGFloat = 26
        static let avatar: CGFloat = 44
    }

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack(alignment: .top) {
                StreamBackdrop(url: model.heroTitle.flatMap { $0.heroArt ?? $0.tileArt }, size: geo.size)
                if model.home == nil || model.isLoading {
                    InterstitialView(title: model.service.name, subtitle: "Loading…", colors: ServiceLook.colors(model.service.id),
                                     header: .streamLoading)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(s).padding(.top, ScreenHeader<EmptyView, EmptyView>.band * s)
                        rows(s, width: geo.size.width)
                    }
                    .transition(.opacity)
                    topBar(s).pinnedToTop()
                }
                if let notice = model.notice {
                    Text(notice).font(DS.ui(22, s, .semibold)).foregroundStyle(DS.text)
                        .padding(.horizontal, 28 * s).padding(.vertical, 14 * s)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 40 * s)
                        .transition(.opacity)
                }
                if let picked = model.picker { ProfilePickerOverlay(profiles: model.home?.profiles ?? [], selected: picked, currentID: model.home?.currentProfileID, s: s, size: geo.size) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
            .animation(DS.crossfade, value: model.home == nil || model.isLoading)
            .animation(DS.fade, value: model.picker != nil)
            .animation(DS.fade, value: model.notice)
        }
        .ignoresSafeArea()
    }

    // MARK: Top bar

    private func topBar(_ s: CGFloat) -> some View {
        let target = model.target
        let profile = model.home?.currentProfile
        return ScreenHeader(kind: .streamHome, s: s, leading: {
            chip(focused: target == .search, s: s) {
                Image(systemName: "magnifyingglass").font(.system(size: 24 * s, weight: .bold))
                Text("Search").font(DS.ui(23, s, .bold))
            }
        }, accessory: {
            if let profile {
                chip(focused: target == .profile, s: s) {
                    avatar(profile, s: s)
                    Text(profile.name).font(DS.ui(23, s, .bold))
                }
            }
        })
    }

    private func chip<Content: View>(focused: Bool, s: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12 * s) { content() }
            .foregroundStyle(focused ? Color.black : DS.text)
            .padding(.horizontal, 24 * s).padding(.vertical, 12 * s)
            .background(Capsule().fill(focused ? Color.white : DS.surfaceStrong))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(DS.focusSpring, value: focused)
    }

    private func avatar(_ profile: StreamProfile, s: CGFloat) -> some View { ProfileAvatar(profile: profile, side: Metrics.avatar * s, s: s) }

    // MARK: Hero

    private func hero(_ s: CGFloat) -> some View {
        Group {
            if let title = model.heroTitle { StreamHeroText(title: title, s: s) }
        }
        .padding(.horizontal, StreamLayout.page * s)
        .padding(.bottom, 22 * s)   // breathing room above the first row's title
        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight * s, maxHeight: Metrics.heroHeight * s, alignment: .bottomLeading)
        .animation(DS.fade, value: model.heroTitle?.id)
    }

    // MARK: Rows

    private func rows(_ s: CGFloat, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Metrics.rowGap * s) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { r, row in
                        rowView(row, index: r, s: s, width: width).id(row.id)
                    }
                }
                .padding(.bottom, 80 * s)
            }
            .onChange(of: model.focusedRow?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func rowView(_ row: StreamRow, index r: Int, s: CGFloat, width: CGFloat) -> some View {
        let column = model.column(inRow: r)
        let focusedRow = model.focusedRow?.id == row.id
        let focusedColumn = focusedRow ? column : nil
        let window = StreamFocus.visibleWindow(count: row.titles.count, focusedColumn: column)
        let slide = RowSlide.offset(focusedColumn: column, step: StreamLayout.tileStep * s)
        return VStack(alignment: .leading, spacing: Metrics.rowTitleGap * s) {
            Text(row.title).font(DS.ui(26, s, .bold)).foregroundStyle(focusedRow ? DS.text : DS.text2)
                .padding(.horizontal, StreamLayout.page * s)
            ZStack(alignment: .leading) {
                ForEach(window, id: \.self) { i in
                    StreamTile(title: row.titles[i], rank: row.kind == .ranked ? i + 1 : nil, focused: focusedColumn == i, s: s)
                        .offset(x: StreamLayout.page * s + CGFloat(i) * StreamLayout.tileStep * s - slide)
                }
            }
            .frame(width: width, height: (StreamLayout.tileHeight + Metrics.tileInset * 2) * s, alignment: .leading)
            .animation(DS.slide, value: column)
        }
    }
}
