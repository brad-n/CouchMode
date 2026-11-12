// Owns: finding a service's reader package (its manifest and reader.js) and
// handing it to the generic reader. Two places hold packages: the copy
// bundled in the app (Resources/apps/<id>/, or the repo's apps/<id>/ when run
// from the repo) and a downloaded copy (Application Support/<bundle
// id>/apps/<id>/, written by PackageUpdater). A downloaded copy is used only
// when its files still hash to what was verified at download and it is not
// older than the bundled one (PackagePolicy.choose); otherwise the bundled
// copy is used. Files are read once, size-bounded, and the manifest is parsed
// strictly; an unusable package is logged and is simply absent.

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

/// Where packages live on disk, and reading one directory. Pure file work, usable off the main thread.
enum PackageFiles {
    static let log = Logger(subsystem: "local.brad.htpcshell", category: "package")
    static let manifestBytes = PackageManifest.maxBytes
    static let scriptBytes = 256 * 1024
    static let verifiedName = "verified.json"

    /// The id becomes a path component: only a plain id is looked up.
    static func plainID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static var bundledRoots: [URL] {
        [Bundle.main.resourceURL?.appendingPathComponent("apps"),
         URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("apps")].compactMap { $0 }
    }

    static var downloadedRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.brad.htpcshell").appendingPathComponent("apps")
    }

    /// Reads and parses one package directory; nil (with a log line) when it is not usable.
    static func read(_ dir: URL, id: String) -> ReaderPackage? {
        guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        do {
            let manifest = try PackageManifest.parse(manifestData)
            guard manifest.id == id else { log.error("package \(id, privacy: .public): manifest id differs"); return nil }
            let script = try Data(contentsOf: dir.appendingPathComponent("reader.js"))
            guard script.count <= scriptBytes, let source = String(data: script, encoding: .utf8) else {
                log.error("package \(id, privacy: .public): reader.js is too large or not text"); return nil
            }
            return ReaderPackage(manifest: manifest, source: source)
        } catch {
            log.error("package \(id, privacy: .public) unusable: \(String(describing: error).prefix(120), privacy: .public)")
            return nil
        }
    }

    static func bundled(_ id: String) -> ReaderPackage? {
        guard plainID(id) else { return nil }
        for root in bundledRoots {
            let dir = root.appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return read(dir, id: id) }
        }
        return nil
    }

    /// The downloaded copy, only if its files still match what was verified when it was installed.
    static func downloaded(_ id: String) -> ReaderPackage? {
        guard plainID(id), let dir = downloadedRoot?.appendingPathComponent(id),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(verifiedName).path) else { return nil }
        guard let marker = try? Data(contentsOf: dir.appendingPathComponent(verifiedName)),
              let entry = (try? PackageIndex.parse(marker))?.entry(id: id) else {
            log.error("downloaded package \(id, privacy: .public): verification record unreadable; ignored"); return nil
        }
        var contents: [String: Data] = [:]
        for f in entry.files {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.name)) else { break }
            contents[f.name] = data
        }
        guard entry.verify(contents) == .ok else {
            log.error("downloaded package \(id, privacy: .public): files no longer match their hashes; ignored"); return nil
        }
        guard let package = read(dir, id: id), package.manifest.version == entry.version else { return nil }
        return package
    }

    /// Ids that have a bundled or downloaded directory, sorted.
    static func knownIDs() -> [String] {
        var ids = Set<String>()
        for root in bundledRoots + [downloadedRoot].compactMap({ $0 }) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where plainID(name) {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent("manifest.json").path) { ids.insert(name) }
            }
        }
        return ids.sorted()
    }
}

/// The best usable copy: a verified download, else the bundled one (see PackagePolicy.choose).
@MainActor
struct LayeredPackageStore: PackageStore {
    func package(for serviceID: String) -> ReaderPackage? {
        let down = PackageFiles.downloaded(serviceID), bundled = PackageFiles.bundled(serviceID)
        switch PackagePolicy.choose(downloaded: down?.manifest.version, bundled: bundled?.manifest.version) {
        case .downloaded: return down
        case .bundled: return bundled
        case .none: return nil
        }
    }

    /// What is in use for each package, for the Apps screen: id, version, and where it came from.
    func installed() -> [(id: String, version: String, source: String)] {
        PackageFiles.knownIDs().compactMap { id in
            let down = PackageFiles.downloaded(id), bundled = PackageFiles.bundled(id)
            switch PackagePolicy.choose(downloaded: down?.manifest.version, bundled: bundled?.manifest.version) {
            case .downloaded: return (id, down?.manifest.version ?? "", "downloaded")
            case .bundled: return (id, bundled?.manifest.version ?? "", "bundled")
            case .none: return nil
            }
        }
    }
}
