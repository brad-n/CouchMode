// Owns: which reader a service uses, from the per-app `reader` setting in a
// Mac's config: the built-in Swift reader (the default) or the service's
// script package. Anything else, or no setting, means the built-in reader, so
// a typo can never leave a service without one.

import Foundation

public enum ReaderMode: String, Equatable, Sendable {
    case builtin, package

    /// The per-app setting that chooses the reader.
    public static let settingKey = "reader"

    public static func from(_ value: ConfigValue?) -> ReaderMode {
        guard case .string(let text)? = value else { return .builtin }
        return ReaderMode(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) ?? .builtin
    }
}
