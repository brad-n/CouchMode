import XCTest
@testable import CouchModeCore

final class PackageManifestTests: XCTestCase {
    private func primeManifest() throws -> PackageManifest {
        try PackageManifest.parse(Data(contentsOf: PrimePackageParityTests.appDirectory.appendingPathComponent("manifest.json")))
    }

    func testPrimeManifestParses() throws {
        let m = try primeManifest()
        XCTAssertEqual(m.id, "prime")
        XCTAssertEqual(Set(m.pages.keys), Set(PackageManifest.PageKind.allCases))
        XCTAssertEqual(m.pages[.search]?.readyRequired, false)
        XCTAssertEqual(m.pages[.profile]?.confirmTimeout, .seconds(15))
        XCTAssertEqual(m.readTimeout, .seconds(12))
        XCTAssertTrue(m.definesPlayerShown)
    }

    func testAddressesAreFilledInAndStayOnTheServicesHosts() throws {
        let m = try primeManifest()
        XCTAssertEqual(m.url(for: .home)?.absoluteString, "https://www.primevideo.com/")
        XCTAssertEqual(m.url(for: .season, .init(seasonID: "S2season01"))?.absoluteString, "https://www.primevideo.com/detail/S2season01")
        XCTAssertNil(m.url(for: .season, .init(seasonID: "a/b")))
        XCTAssertNil(m.url(for: .season))
        XCTAssertEqual(m.url(for: .details, .init(titlePage: URL(string: "https://www.primevideo.com/detail/ABCD1234")))?.path, "/detail/ABCD1234")
        XCTAssertNil(m.url(for: .details, .init(titlePage: URL(string: "https://evil.example/detail/ABCD1234"))), "off the service's hosts")
        XCTAssertNil(m.url(for: .details, .init(titlePage: URL(string: "http://www.primevideo.com/detail/ABCD1234"))), "not https")
        XCTAssertNil(m.url(for: .details))
        let search = try XCTUnwrap(m.url(for: .search, .init(query: "the & garden é")))
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "the & garden é")
        XCTAssertEqual(search.host, "www.primevideo.com")
        XCTAssertNil(m.url(for: .search, .init(query: "   ")))
    }

    func testBadManifestsAreRefused() throws {
        func parse(_ json: String) throws -> PackageManifest { try PackageManifest.parse(Data(json.utf8)) }
        let ok = #"{"id":"x","version":"1","readerAPI":1,"site":{"hosts":["example.invalid"]},"pages":{"home":{"open":"https://example.invalid/","ready":"homeReady"}}}"#
        XCTAssertNoThrow(try parse(ok))
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: #""readerAPI":1"#, with: #""readerAPI":2"#)))
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: #""id":"x""#, with: #""id":"../x""#)))
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: "https://example.invalid/", with: "http://example.invalid/")))
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: "homeReady", with: "x(); evil")))
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: "https://example.invalid/", with: "https://example.invalid/{other}")))
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: #""pages":{"home""#, with: #""pages":{"search""#)), "home is required")
        XCTAssertThrowsError(try parse(ok.replacingOccurrences(of: #"["example.invalid"]"#, with: "[]")))
        XCTAssertThrowsError(try parse("[]"))
        XCTAssertThrowsError(try PackageManifest.parse(Data(count: PackageManifest.maxBytes + 1)))
    }

    func testReaderSettingDefaultsToBuiltin() {
        XCTAssertEqual(ReaderMode.from(nil), .builtin)
        XCTAssertEqual(ReaderMode.from(.string("package")), .package)
        XCTAssertEqual(ReaderMode.from(.string(" Package ")), .package)
        XCTAssertEqual(ReaderMode.from(.string("builtin")), .builtin)
        XCTAssertEqual(ReaderMode.from(.string("nonsense")), .builtin)
        XCTAssertEqual(ReaderMode.from(.bool(true)), .builtin)
    }

    func testCatalogDefaultAppliesOnlyWithoutASetting() {
        XCTAssertEqual(ReaderMode.from(nil, catalogDefault: "package"), .package)
        XCTAssertEqual(ReaderMode.from(.string("builtin"), catalogDefault: "package"), .builtin)
        XCTAssertEqual(ReaderMode.from(.string("junk"), catalogDefault: "package"), .builtin)
        XCTAssertEqual(ReaderMode.from(nil, catalogDefault: "junk"), .builtin)
    }
}
