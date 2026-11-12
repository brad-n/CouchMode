// Owns: finding a service's reader package (its manifest and reader.js) and
// handing it to the generic reader, behind one small seam so where packages
// come from can grow (a downloaded copy comes later) without the reader
// changing. Today: the copy bundled in the app (Resources/apps/<id>/), or the
// repo's apps/<id>/ when run from the repo. Files are read once, size-bounded,
// and the manifest is parsed strictly; an unusable package is logged and is
// simply absent.

import Foundation
import os
import CouchModeCore

/// A package ready to run: its parsed manifest and its reader script's source.
struct ReaderPackage {
    let manifest: PackageManifest
    let source: String
}

@MainActor
protocol PackageStore {
    /// The package for a service id; nil when there is none or it is unusable.
    func package(for serviceID: String) -> ReaderPackage?
}

@MainActor
struct BundledPackageStore: PackageStore {
    private enum Limits { static let scriptBytes = 256 * 1024 }
    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "package")

    func package(for serviceID: String) -> ReaderPackage? {
        // The id becomes a path component: only a plain id is looked up.
        guard !serviceID.isEmpty, serviceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let roots = [Bundle.main.resourceURL?.appendingPathComponent("apps"),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("apps")]
        for root in roots.compactMap({ $0 }) {
            let dir = root.appendingPathComponent(serviceID)
            guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { continue }
            // TODO(M3): check a downloaded package's hash against the published one before using it.
            do {
                let manifest = try PackageManifest.parse(manifestData)
                guard manifest.id == serviceID else { Self.log.error("package \(serviceID, privacy: .public): manifest id differs"); return nil }
                let script = try Data(contentsOf: dir.appendingPathComponent("reader.js"))
                guard script.count <= Limits.scriptBytes, let source = String(data: script, encoding: .utf8) else {
                    Self.log.error("package \(serviceID, privacy: .public): reader.js is too large or not text"); return nil
                }
                return ReaderPackage(manifest: manifest, source: source)
            } catch {
                Self.log.error("package \(serviceID, privacy: .public) unusable: \(String(describing: error).prefix(120), privacy: .public)")
                return nil
            }
        }
        return nil
    }
}
