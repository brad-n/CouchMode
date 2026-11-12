// Owns: running one script in Plex HTPC's page through the app's web
// inspector (Chrome's DevTools protocol on 127.0.0.1, served only when
// plex.ini turns it on, which PlexHTPC does). Bounded: short timeouts to find
// the page and for the script, replies capped. What to run and how to read
// the answer is CouchModeCore's PlexInspector; when to run it is PlexHTPC's.

import Foundation
import os
import CouchModeCore

@MainActor
final class PlexInspectorClient {
    private enum Limits {
        static let listTimeout: TimeInterval = 2
        static let socketTimeout: TimeInterval = 20
        static let scriptTimeout: Duration = .seconds(15)
        static let maxReplyBytes = 1 << 20
        /// Events read while waiting for the script's reply.
        static let maxMessages = 200
    }
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "plexinspector")
    private let listSession = PlexInspectorClient.session(timeout: Limits.listTimeout)
    private let socketSession = PlexInspectorClient.session(timeout: Limits.socketTimeout)
    private let listURL = URL(string: "http://127.0.0.1:\(PlexInspector.port)/json")!

    private static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: c)
    }

    /// The app's page socket, when the inspector answers.
    func pageSocket() async -> URL? {
        guard let (data, response) = try? await listSession.data(from: listURL),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return PlexInspector.pageSocket(fromTargets: data)
    }

    /// Runs `script` in the app's page and reads its report.
    func run(_ script: String) async -> PlexInspector.Outcome {
        guard let socketURL = await pageSocket() else { return .unavailable("inspector not answering") }
        let socket = socketSession.webSocketTask(with: socketURL)
        socket.maximumMessageSize = Limits.maxReplyBytes
        socket.resume()
        let deadline = Task {
            try? await Task.sleep(for: Limits.scriptTimeout)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            deadline.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        let requestID = 1
        do {
            try await socket.send(.string(PlexInspector.evaluateRequest(id: requestID, expression: script)))
        } catch {
            return .unavailable("couldn't reach the page: \(error.localizedDescription)")
        }
        // From here the script may be running: a lost reply is a failure, not a reason to try keys.
        do {
            for _ in 0..<Limits.maxMessages {
                let text: String
                switch try await socket.receive() {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                if let outcome = PlexInspector.outcome(fromReply: text, id: requestID) { return outcome }
            }
            return .failed("no reply among \(Limits.maxMessages) messages")
        } catch {
            return .failed("no reply: \(error.localizedDescription)")
        }
    }
}
