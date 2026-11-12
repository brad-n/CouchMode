// Owns: which reader a service uses, from the per-app `reader` setting in a
// Mac's config: the built-in Swift reader (the default) or the service's
// script package. Anything else means the built-in reader, so
// a typo can never leave a service without one.

import Foundation

public enum ReaderMode: String, Equatable, Sendable {
    case builtin, package

    /// The per-app setting that chooses the reader.
    public static let settingKey = "reader"

    /// The Mac's setting wins (so `builtin` stays builtin); with none, the catalog's default for the app; with none of
    /// those, the package once the service has one; else built-in.
    public static func from(_ value: ConfigValue?, catalogDefault: String? = nil, packagePresent: Bool = false) -> ReaderMode {
        func mode(_ text: String) -> ReaderMode? { ReaderMode(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) }
        if let value {
            guard case .string(let text) = value else { return .builtin }
            return mode(text) ?? .builtin
        }
        return catalogDefault.flatMap(mode) ?? (packagePresent ? .package : .builtin)
    }
}
