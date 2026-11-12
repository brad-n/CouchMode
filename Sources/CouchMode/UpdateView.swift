// Owns: the software update screen: the shared launch card (InterstitialView)
// showing the current update phase, with remote-driven buttons. Pure
// presentation of AppUpdater's flow; presses are routed by the coordinator.

import AppKit
import SwiftUI
import CouchModeCore

struct UpdateView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        let phase = updater.flow.phase
        let focus = updater.flow.focused
        InterstitialView(
            title: phase.title, subtitle: phase.subtitle, colors: [DS.accent],
            icon: NSApp.applicationIconImage, header: .settings,
            progress: fraction(phase), showsBar: showsBar(phase),
            detail: notes(phase), buttons: updater.flow.buttons.map(\.label),
            focusedButton: updater.flow.buttons.firstIndex { $0 == focus } ?? 0)
    }

    private func fraction(_ phase: UpdateFlow.Phase) -> Double? {
        if case .downloading(let f) = phase { return f }
        return nil
    }

    private func showsBar(_ phase: UpdateFlow.Phase) -> Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private func notes(_ phase: UpdateFlow.Phase) -> String? {
        if case .available(_, let notes) = phase { return notes }
        return nil
    }
}
