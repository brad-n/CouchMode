// Owns: the Sparkle user driver for a TV. Turns each Sparkle update moment
// into an UpdateFlow event and keeps Sparkle's reply closures for the
// presses that answer them. Shows no window of its own: the update screen
// and the Home notice draw from the flow. Automatic checks stay silent
// except for remembering a found update (the Home notice).

import Foundation
import Sparkle
import CouchModeCore

@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    private enum Limits {
        static let noteLines = 5
        static let noteChars = 400
    }

    private unowned let owner: AppUpdater

    init(updater: AppUpdater) { owner = updater }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner.cancelHandler = cancellation
        owner.apply(.checkStarted)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let notes = ReleaseNotes.summary(html: appcastItem.itemDescription, maxLines: Limits.noteLines, maxChars: Limits.noteChars)
        if appcastItem.isInformationOnlyUpdate {
            // Nothing to install from here (the item only points at a web page).
            owner.apply(.notFound)
            reply(.dismiss)
            return
        }
        owner.apply(.found(version: appcastItem.displayVersionString, notes: notes,
                           userInitiated: UpdateNotice.mayOpenScreen(userInitiated: state.userInitiated)))
        if case .available = owner.flow.phase {
            owner.foundReply = reply
        } else {
            // An automatic find only leaves the Home notice: nothing waits on a person.
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner.apply(.notFound)
        finish(acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        owner.apply(.failed(UpdateFailure.classify(domain: e.domain, code: e.code, message: e.localizedDescription)))
        finish(acknowledgement)
    }

    /// Holds the acknowledgement for the OK press; with no screen waiting, answers it at once.
    private func finish(_ acknowledgement: @escaping () -> Void) {
        if owner.flow.phase == .idle { acknowledgement() } else { owner.acknowledgement = acknowledgement }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner.cancelHandler = cancellation
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner.apply(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) { owner.apply(.received(length)) }

    func showDownloadDidStartExtractingUpdate() { owner.apply(.extracting) }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // "Install now" was already the person's answer.
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner.apply(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func dismissUpdateInstallation() {
        owner.foundReply = nil
        owner.cancelHandler = nil
        owner.acknowledgement = nil
        owner.apply(.dismissed)
    }

    func showUpdateInFocus() {}
}
