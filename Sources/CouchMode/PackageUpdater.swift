// Owns: fetching app packages from the repo on GitHub: the index, then each
// package that is newer than the best copy here and speaks a reader API this
// app supports. Every file is checked against the index's sha256 and the
// manifest is parsed before anything is written; a package is installed
// whole (a temporary folder swapped in atomically) or not at all. Any failure
// logs one line and changes nothing, so the last good copy stays. Plain
// URLSession with short timeouts and size caps; no retries or background
// loops (the coordinator decides when to ask: at most daily, or on demand).
// Hashes guard against corruption; the index is not signed (agents/release.md).

import Foundation
import os
import CouchModeCore

struct PackageUpdateResult {
    let report: PackageUpdateReport
    let installedIDs: [String]
}

final class PackageUpdater: Sendable {
    static let shared = PackageUpdater()
    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "package")
    private enum Limits { static let request: TimeInterval = 10; static let resource: TimeInterval = 30 }

    private struct Fetch: Error { let status: Int?; let why: String }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Limits.request
        c.timeoutIntervalForResource = Limits.resource
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Fetches the index from `ref` (nil is `main`) and installs what is newer. Never throws.
    func check(ref: String?) async -> PackageUpdateResult {
        guard let indexURL = PackageSource.url(ref: ref, path: "index.json") else {
            Self.log.error("package check: the configured packageRef is not usable")
            return PackageUpdateResult(report: PackageUpdateReport(index: .unusable), installedIDs: [])
        }
        let data: Data
        do { data = try await get(indexURL, maxBytes: PackageIndex.maxBytes) }
        catch let e as Fetch {
            if e.status == 404 {
                Self.log.info("package check: no index published at this ref yet")
                return PackageUpdateResult(report: PackageUpdateReport(index: .missing), installedIDs: [])
            }
            Self.log.error("package check: index not fetched (\(e.why, privacy: .public))")
            return PackageUpdateResult(report: PackageUpdateReport(index: e.status == nil ? .unreachable : .unusable), installedIDs: [])
        } catch {
            Self.log.error("package check: index not fetched")
            return PackageUpdateResult(report: PackageUpdateReport(index: .unreachable), installedIDs: [])
        }
        let index: PackageIndex
        do { index = try PackageIndex.parse(data) }
        catch {
            Self.log.error("package check: index unusable: \(String(describing: error).prefix(120), privacy: .public)")
            return PackageUpdateResult(report: PackageUpdateReport(index: .unusable), installedIDs: [])
        }

        var report = PackageUpdateReport(index: .read), ids: [String] = []
        for entry in index.packages {
            let installed = PackagePolicy.newest(PackageFiles.bundled(entry.id)?.manifest.version, PackageFiles.downloaded(entry.id)?.manifest.version)
            switch PackagePolicy.decide(entry, installed: installed, supportedAPI: PackageManifest.supportedAPI) {
            case .upToDate: continue
            case .unsupportedAPI(let api):
                Self.log.info("package \(entry.id, privacy: .public): needs reader API \(api); skipped")
                report.unsupported.append(entry.id)
            case .download:
                do {
                    try await install(entry, ref: ref)
                    report.installed.append("\(entry.id) \(entry.version)")
                    ids.append(entry.id)
                    Self.log.info("package \(entry.id, privacy: .public) \(entry.version, privacy: .public) installed")
                } catch {
                    let why = (error as? Fetch)?.why ?? String(describing: error).prefix(100).description
                    Self.log.error("package \(entry.id, privacy: .public): update failed, nothing changed (\(why, privacy: .public))")
                    report.failed.append(entry.id)
                }
            }
        }
        return PackageUpdateResult(report: report, installedIDs: ids)
    }

    private func install(_ entry: PackageIndex.Entry, ref: String?) async throws {
        guard PackageFiles.plainID(entry.id), let root = PackageFiles.downloadedRoot else { throw Fetch(status: nil, why: "no place to install") }
        var contents: [String: Data] = [:]
        for file in entry.files {
            guard let url = PackageSource.url(ref: ref, path: "\(entry.id)/\(file.name)") else { throw Fetch(status: nil, why: "bad address") }
            contents[file.name] = try await get(url, maxBytes: file.name == "manifest.json" ? PackageFiles.manifestBytes : PackageFiles.scriptBytes)
        }
        switch entry.verify(contents) {
        case .ok: break
        case .missing(let n): throw Fetch(status: nil, why: "\(n) missing")
        case .mismatch(let n): throw Fetch(status: nil, why: "\(n) does not match its hash")
        }
        guard let manifestData = contents["manifest.json"], let script = contents["reader.js"], String(data: script, encoding: .utf8) != nil else {
            throw Fetch(status: nil, why: "manifest.json and reader.js are required")
        }
        let manifest = try PackageManifest.parse(manifestData)
        guard manifest.id == entry.id, manifest.version == entry.version else { throw Fetch(status: nil, why: "manifest differs from the index") }

        // The verification record is a one-package index, checked again every time the copy is loaded.
        let record = try JSONSerialization.data(withJSONObject: [
            "version": PackageIndex.supportedVersion,
            "packages": [["id": entry.id, "version": entry.version, "readerAPI": entry.readerAPI,
                          "files": entry.files.map { ["name": $0.name, "sha256": $0.sha256] }]]], options: [.sortedKeys])
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".\(entry.id).new")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for (name, data) in contents { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
            try record.write(to: staging.appendingPathComponent(PackageFiles.verifiedName), options: .atomic)
            let final = root.appendingPathComponent(entry.id)
            if fm.fileExists(atPath: final.path) { _ = try fm.replaceItemAt(final, withItemAt: staging) }
            else { try fm.moveItem(at: staging, to: final) }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// One GET, https only, with a byte cap enforced while reading.
    private func get(_ url: URL, maxBytes: Int) async throws -> Data {
        guard url.scheme == "https", url.host == PackageSource.host else { throw Fetch(status: nil, why: "not the package host") }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { throw Fetch(status: nil, why: "no response") }
            guard http.statusCode == 200 else { throw Fetch(status: http.statusCode, why: "HTTP \(http.statusCode)") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw Fetch(status: http.statusCode, why: "over \(maxBytes) bytes") }
            }
            return data
        } catch let e as Fetch { throw e }
        catch { throw Fetch(status: nil, why: (error as NSError).localizedDescription) }
    }
}
