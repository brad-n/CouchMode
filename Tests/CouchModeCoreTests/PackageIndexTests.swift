// Owns: tests for the package index (parsing, hash verification, the check
// that the repo's apps/index.json matches the files), version comparison,
// the download and source-preference decisions, the daily schedule,
// package addresses and the update result line.

import XCTest
@testable import CouchModeCore

private let sampleHash = String(repeating: "a", count: 64)

private func indexJSON(_ packages: String, version: Int = 1) -> Data {
    Data(#"{"version":\#(version),"packages":[\#(packages)]}"#.utf8)
}

private func pkg(_ id: String = "hulu", version: String = "1.0.0", api: Int = 1, hash: String = sampleHash) -> String {
    #"{"id":"\#(id)","version":"\#(version)","readerAPI":\#(api),"files":[{"name":"manifest.json","sha256":"\#(hash)"},{"name":"reader.js","sha256":"\#(hash)"}]}"#
}

final class PackageIndexTests: XCTestCase {
    func testParsesAnIndex() throws {
        let index = try PackageIndex.parse(indexJSON(pkg("hulu") + "," + pkg("prime", version: "2.1")))
        XCTAssertEqual(index.packages.map(\.id), ["hulu", "prime"])
        XCTAssertEqual(index.entry(id: "prime")?.version, "2.1")
        XCTAssertEqual(index.entry(id: "hulu")?.files.map(\.name), ["manifest.json", "reader.js"])
        XCTAssertNil(index.entry(id: "nope"))
    }

    func testRejectsBadIndexes() {
        func fails(_ data: Data, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try PackageIndex.parse(data), why, line: line)
        }
        fails(Data("nope".utf8), "not json")
        fails(indexJSON(pkg(), version: 2), "unsupported index version")
        fails(indexJSON(pkg() + "," + pkg()), "duplicate id")
        fails(indexJSON(pkg("../x")), "path-like id")
        fails(indexJSON(pkg(version: "latest")), "unreadable version")
        fails(indexJSON(pkg(hash: "xyz")), "short hash")
        fails(indexJSON(pkg(hash: String(repeating: "A", count: 64))), "upper-case hash")
        fails(indexJSON(#"{"id":"a","version":"1","readerAPI":1,"files":[{"name":"../etc","sha256":"\#(sampleHash)"}]}"#), "path file name")
        fails(indexJSON(#"{"id":"a","version":"1","readerAPI":1,"files":[]}"#), "no files")
        fails(Data(repeating: 32, count: PackageIndex.maxBytes + 1), "too large")
    }

    func testVerifyNeedsEveryFileToMatch() throws {
        let manifest = Data("{}".utf8), script = Data("const reader = {}".utf8)
        let entry = PackageIndex.Entry(id: "x", version: "1.0.0", readerAPI: 1, files: [
            .init(name: "manifest.json", sha256: PackageIndex.sha256Hex(manifest)),
            .init(name: "reader.js", sha256: PackageIndex.sha256Hex(script))])
        XCTAssertEqual(entry.verify(["manifest.json": manifest, "reader.js": script]), .ok)
        XCTAssertEqual(entry.verify(["manifest.json": manifest, "reader.js": Data("changed".utf8)]), .mismatch("reader.js"))
        XCTAssertEqual(entry.verify(["manifest.json": manifest]), .missing("reader.js"))
        // Known SHA-256 of "abc".
        XCTAssertEqual(PackageIndex.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// apps/index.json must describe the files in apps/<id>/ exactly (scripts/package-index.sh regenerates it).
    func testRepoIndexMatchesThePackageFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let apps = root.appendingPathComponent("apps")
        let index = try PackageIndex.parse(Data(contentsOf: apps.appendingPathComponent("index.json")))
        let dirs = try FileManager.default.contentsOfDirectory(atPath: apps.path).filter {
            FileManager.default.fileExists(atPath: apps.appendingPathComponent($0).appendingPathComponent("manifest.json").path)
        }
        XCTAssertEqual(Set(index.packages.map(\.id)), Set(dirs), "index.json lists exactly the packages in apps/")
        for entry in index.packages {
            var contents: [String: Data] = [:]
            for f in entry.files { contents[f.name] = try Data(contentsOf: apps.appendingPathComponent(entry.id).appendingPathComponent(f.name)) }
            XCTAssertEqual(entry.verify(contents), .ok, "\(entry.id) matches the index")
            let manifest = try PackageManifest.parse(contents["manifest.json"] ?? Data())
            XCTAssertEqual(manifest.version, entry.version, "\(entry.id) version")
            XCTAssertEqual(manifest.id, entry.id)
            XCTAssertEqual(entry.readerAPI, PackageManifest.supportedAPI)
        }
    }
}

final class PackagePolicyTests: XCTestCase {
    func testVersionOrder() {
        func v(_ s: String) -> PackageVersion { PackageVersion(s)! }
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertLessThan(v("1.9"), v("1.10"))
        XCTAssertEqual(v("1.0"), v("1.0.0"))
        XCTAssertNil(PackageVersion(""))
        XCTAssertNil(PackageVersion("1.x"))
        XCTAssertNil(PackageVersion("1..2"))
        XCTAssertNil(PackageVersion("1.2.3.4.5.6.7"))
        XCTAssertTrue(PackageVersion.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertFalse(PackageVersion.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(PackageVersion.isNewer("0.9", than: "1.0.0"))
        XCTAssertTrue(PackageVersion.isNewer("1.0.0", than: nil), "nothing installed")
        XCTAssertTrue(PackageVersion.isNewer("1.0.0", than: "garbage"), "unreadable installed version")
        XCTAssertFalse(PackageVersion.isNewer("garbage", than: "1.0.0"))
    }

    func testDecideDownload() {
        func entry(_ version: String, api: Int = 1) -> PackageIndex.Entry { .init(id: "x", version: version, readerAPI: api, files: []) }
        XCTAssertEqual(PackagePolicy.decide(entry("1.1.0"), installed: "1.0.0", supportedAPI: 1), .download)
        XCTAssertEqual(PackagePolicy.decide(entry("1.0.0"), installed: "1.0.0", supportedAPI: 1), .upToDate)
        XCTAssertEqual(PackagePolicy.decide(entry("1.0.0"), installed: nil, supportedAPI: 1), .download)
        XCTAssertEqual(PackagePolicy.decide(entry("9.0.0", api: 2), installed: "1.0.0", supportedAPI: 1), .unsupportedAPI(2))
        XCTAssertEqual(PackagePolicy.newest("1.0.0", "1.2.0"), "1.2.0")
        XCTAssertEqual(PackagePolicy.newest(nil, "1.2.0"), "1.2.0")
        XCTAssertNil(PackagePolicy.newest(nil, nil))
    }

    func testSourcePreference() {
        XCTAssertEqual(PackagePolicy.choose(downloaded: "1.1.0", bundled: "1.0.0"), .downloaded)
        XCTAssertEqual(PackagePolicy.choose(downloaded: "1.0.0", bundled: "1.0.0"), .downloaded)
        XCTAssertEqual(PackagePolicy.choose(downloaded: "1.0.0", bundled: "1.2.0"), .bundled, "the app shipped a newer copy")
        XCTAssertEqual(PackagePolicy.choose(downloaded: nil, bundled: "1.0.0"), .bundled)
        XCTAssertEqual(PackagePolicy.choose(downloaded: "1.0.0", bundled: nil), .downloaded)
        XCTAssertEqual(PackagePolicy.choose(downloaded: nil, bundled: nil), .none)
    }

    func testDailySchedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateSchedule.isDue(last: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(last: now.addingTimeInterval(500), now: now), "clock went backwards")
    }

    func testAddresses() {
        XCTAssertEqual(PackageSource.url(ref: nil, path: "index.json")?.absoluteString,
                       "https://raw.githubusercontent.com/brad-n/CouchMode/main/apps/index.json")
        XCTAssertEqual(PackageSource.url(ref: "release/1.0", path: "hulu/reader.js")?.absoluteString,
                       "https://raw.githubusercontent.com/brad-n/CouchMode/release/1.0/apps/hulu/reader.js")
        XCTAssertNil(PackageSource.url(ref: "../x", path: "index.json"))
        XCTAssertNil(PackageSource.url(ref: "main", path: "../secret"))
        XCTAssertNil(PackageSource.url(ref: "a b", path: "index.json"))
        XCTAssertNil(PackageSource.url(ref: "main", path: "a/b/c"))
    }

    func testReportLines() {
        XCTAssertEqual(PackageUpdateReport(index: .missing).line, "No app updates are published yet.")
        XCTAssertEqual(PackageUpdateReport(index: .unreachable).line, "Couldn't reach GitHub. Your apps are unchanged.")
        XCTAssertEqual(PackageUpdateReport(index: .read).line, "App packages are up to date.")
        XCTAssertEqual(PackageUpdateReport(index: .read, installed: ["hulu 1.0.1"]).line, "Updated hulu 1.0.1.")
        XCTAssertEqual(PackageUpdateReport(index: .read, failed: ["prime"]).line, "Couldn't update prime. Your apps are unchanged.")
        XCTAssertEqual(PackageUpdateReport(index: .read, installed: ["hulu 1.0.1"], failed: ["prime"]).line, "Updated hulu 1.0.1. Couldn't update prime.")
    }
}
