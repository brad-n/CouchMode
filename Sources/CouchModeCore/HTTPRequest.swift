// Owns: parsing one small HTTP/1.x request for the opt-in debug channel.

import Foundation

/// Minimal HTTP request parser: returns nil until headers (and the declared
/// body) have fully arrived.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data

    public init?(_ data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let comps = URLComponents(string: String(parts[1]))
        method = String(parts[0])
        path = comps?.path ?? "/"
        query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        body = data[bodyStart..<(bodyStart + length)]
    }
}
