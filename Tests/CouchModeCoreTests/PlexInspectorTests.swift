import XCTest
@testable import CouchModeCore

final class PlexInspectorTests: XCTestCase {
    private let server = "0123456789abcdef0123456789abcdef01234567"

    // MARK: the library copy's address

    func testSourceURIPointsAtTheServersLibraryCopy() {
        XCTAssertEqual(PlexInspector.sourceURI(machineIdentifier: server, ratingKey: "424242"),
                       "server://\(server)/com.plexapp.plugins.library/library/metadata/424242")
    }

    func testSourceURIRefusesAnythingButPlainIDs() {
        XCTAssertNil(PlexInspector.sourceURI(machineIdentifier: "", ratingKey: "1"))
        XCTAssertNil(PlexInspector.sourceURI(machineIdentifier: server, ratingKey: ""))
        XCTAssertNil(PlexInspector.sourceURI(machineIdentifier: "abc/def", ratingKey: "1"))
        XCTAssertNil(PlexInspector.sourceURI(machineIdentifier: "abc\"); x(\"", ratingKey: "1"))
        XCTAssertNil(PlexInspector.sourceURI(machineIdentifier: server, ratingKey: "12a"))
        XCTAssertNil(PlexInspector.sourceURI(machineIdentifier: String(repeating: "a", count: 65), ratingKey: "1"))
    }

    // MARK: plex.ini

    private let ini = "[General]\nversion=1\n\n[debug]\nwebInspectorPort=0\n\n[ui]\nscreen=6\n"

    func testTurnsTheInspectorOnInPlace() {
        XCTAssertEqual(PlexInspector.enablingInspector(in: ini, port: 9223),
                       "[General]\nversion=1\n\n[debug]\nwebInspectorPort=9223\n\n[ui]\nscreen=6\n")
    }

    func testLeavesTheFileAloneWhenAlreadyOn() {
        let on = PlexInspector.enablingInspector(in: ini, port: 9223)!
        XCTAssertNil(PlexInspector.enablingInspector(in: on, port: 9223))
    }

    func testAddsTheSettingToAnExistingDebugSection() {
        XCTAssertEqual(PlexInspector.enablingInspector(in: "[debug]\nother=1\n[ui]\nscreen=6\n", port: 9223),
                       "[debug]\nwebInspectorPort=9223\nother=1\n[ui]\nscreen=6\n")
    }

    func testAddsADebugSectionWhenThereIsNone() {
        XCTAssertEqual(PlexInspector.enablingInspector(in: "[General]\nversion=1\n", port: 9223),
                       "[General]\nversion=1\n\n[debug]\nwebInspectorPort=9223\n")
        XCTAssertEqual(PlexInspector.enablingInspector(in: "", port: 9223), "[debug]\nwebInspectorPort=9223\n")
    }

    func testOnlyTheDebugSectionsSettingCounts() {
        let text = "[web]\nwebInspectorPort=9223\n[debug]\nwebInspectorPort=0\n"
        XCTAssertEqual(PlexInspector.enablingInspector(in: text, port: 9223),
                       "[web]\nwebInspectorPort=9223\n[debug]\nwebInspectorPort=9223\n")
    }

    // MARK: the inspector's page list

    func testPicksTheAppsPageOnThisMac() {
        let json = """
        [{"type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9223/devtools/page/AAA"},
         {"type":"page","url":"file:///Users/example/Applications/Plex%20HTPC.app/Contents/Resources/web-client/index.html",
          "webSocketDebuggerUrl":"ws://127.0.0.1:9223/devtools/page/BBB"}]
        """
        XCTAssertEqual(PlexInspector.pageSocket(fromTargets: Data(json.utf8)),
                       URL(string: "ws://127.0.0.1:9223/devtools/page/BBB"))
    }

    func testRefusesASocketOnAnotherMachine() {
        let json = #"[{"type":"page","url":"file:///web-client/index.html","webSocketDebuggerUrl":"ws://203.0.113.9:9223/devtools/page/BBB"}]"#
        XCTAssertNil(PlexInspector.pageSocket(fromTargets: Data(json.utf8)))
        XCTAssertNil(PlexInspector.pageSocket(fromTargets: Data("not json".utf8)))
    }

    // MARK: the request and its reply

    func testEvaluateRequestWaitsForTheScriptsAnswer() throws {
        let text = PlexInspector.evaluateRequest(id: 7, expression: "1+1")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 7)
        XCTAssertEqual(json["method"] as? String, "Runtime.evaluate")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["expression"] as? String, "1+1")
        XCTAssertEqual(params["awaitPromise"] as? Bool, true)
        XCTAssertEqual(params["returnByValue"] as? Bool, true)
    }

    func testReadsTheScriptsReport() {
        func reply(_ value: String) -> String { #"{"id":1,"result":{"result":{"type":"string","value":"\#(value)"}}}"# }
        XCTAssertEqual(PlexInspector.outcome(fromReply: reply("opened: PreplayScreen"), id: 1), .opened("PreplayScreen"))
        XCTAssertEqual(PlexInspector.outcome(fromReply: reply("unavailable: no app controller"), id: 1), .unavailable("no app controller"))
        XCTAssertEqual(PlexInspector.outcome(fromReply: reply("failed: still on HomeTabbedScreen"), id: 1), .failed("still on HomeTabbedScreen"))
        XCTAssertEqual(PlexInspector.outcome(fromReply: reply("something else"), id: 1), .failed("unexpected reply: something else"))
    }

    func testIgnoresOtherMessagesAndReportsProtocolErrors() {
        XCTAssertNil(PlexInspector.outcome(fromReply: #"{"method":"Runtime.consoleAPICalled","params":{}}"#, id: 1))
        XCTAssertNil(PlexInspector.outcome(fromReply: #"{"id":2,"result":{}}"#, id: 1))
        XCTAssertEqual(PlexInspector.outcome(fromReply: #"{"id":1,"error":{"code":-32000,"message":"nope"}}"#, id: 1),
                       .unavailable("inspector error: nope"))
        // A script that didn't even parse ran nothing.
        XCTAssertEqual(PlexInspector.outcome(fromReply: #"{"id":1,"result":{"result":{"type":"object"},"exceptionDetails":{"text":"SyntaxError"}}}"#, id: 1),
                       .unavailable("script error: SyntaxError"))
    }

    // MARK: the script

    func testScriptCarriesTheAddressAsAQuotedString() {
        let source = PlexInspector.sourceURI(machineIdentifier: server, ratingKey: "424242")!
        let script = PlexInspector.openScript(sourceURI: source)
        XCTAssertTrue(script.hasPrefix("(async () => {"))
        XCTAssertTrue(script.contains("const source = \"server:\\/\\/\(server)\\/com.plexapp.plugins.library\\/library\\/metadata\\/424242\";")
                      || script.contains("const source = \"server://\(server)/com.plexapp.plugins.library/library/metadata/424242\";"))
        XCTAssertTrue(script.contains("processDeepLink({ metadataSourceUri: source })"))
    }
}
