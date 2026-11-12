// Owns: the "Who's watching?" picker drawn over a stream screen (home or
// details): one row per profile with its avatar, a lock mark on a profile that
// needs its PIN on the website, and the focused row highlighted. Drawing only;
// the model owning the selection decides what Select does.

import SwiftUI
import CouchModeCore

struct ProfileAvatar: View {
    let profile: StreamProfile
    let side: CGFloat
    let s: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(DS.accent.opacity(0.85))
            Text(String(profile.name.prefix(1)).uppercased()).font(DS.ui(22, s, .heavy)).foregroundStyle(.black)
            if let url = profile.avatar { RemoteImage(url: url, cover: CGSize(width: side, height: side)) }
        }
        .frame(width: side, height: side).clipShape(Circle())
    }
}

struct ProfilePickerOverlay: View {
    let profiles: [StreamProfile]
    let selected: Int
    let currentID: String?
    let s: CGFloat
    let size: CGSize

    private static let width: CGFloat = 640
    private static let avatar: CGFloat = 44

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
            VStack(alignment: .leading, spacing: 14 * s) {
                Text("Who's watching?").font(DS.display(40, s)).foregroundStyle(DS.text).padding(.bottom, 8 * s)
                ForEach(Array(profiles.enumerated()), id: \.element.id) { i, profile in
                    row(profile, focused: i == selected, current: profile.id == currentID)
                }
            }
            .padding(40 * s)
            .frame(width: Self.width * s)
            .background(RoundedRectangle(cornerRadius: DS.tileRadius * s, style: .continuous).fill(DS.canvas.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: DS.tileRadius * s, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity)
    }

    private func row(_ profile: StreamProfile, focused: Bool, current: Bool) -> some View {
        HStack(spacing: 18 * s) {
            ProfileAvatar(profile: profile, side: Self.avatar * s, s: s)
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(profile.name).font(DS.ui(26, s, .bold))
                if profile.isLocked {
                    Text("Needs its PIN on the website").font(DS.ui(17, s, .medium)).opacity(0.7)
                } else if profile.isKids {
                    Text("Kids").font(DS.ui(17, s, .medium)).opacity(0.7)
                }
            }
            Spacer()
            if profile.isLocked { Image(systemName: "lock.fill").font(.system(size: 22 * s)) }
            else if current { Image(systemName: "checkmark").font(.system(size: 22 * s, weight: .bold)) }
        }
        .foregroundStyle(focused ? Color.black : (profile.isLocked ? DS.text3 : DS.text))
        .padding(.horizontal, 22 * s).padding(.vertical, 14 * s)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius * s, style: .continuous).fill(focused ? Color.white : DS.surface))
        .scaleEffect(focused ? 1.04 : 1)
        .animation(DS.focusSpring, value: focused)
    }
}
