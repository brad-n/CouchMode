// Owns: tests for the media probe's init-segment parsing, run through
// JavaScriptCore against hand-made synthetic fMP4 init segments.

import JavaScriptCore
import XCTest
@testable import CouchModeCore

final class MediaProbeTests: XCTestCase {
    // MARK: synthetic bytes

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(payload.count + 8) + Array(type.utf8) + payload }
    private func full(_ type: String, _ payload: [UInt8]) -> [UInt8] { box(type, [0, 0, 0, 0] + payload) }

    private func audioEntry(_ type: String, child: [UInt8]) -> [UInt8] {
        // 6 reserved + dref index + 8 reserved + channels + size + 4 + rate = 28
        box(type, [UInt8](repeating: 0, count: 6) + [0, 1] + [UInt8](repeating: 0, count: 8) + [0, 2, 0, 16, 0, 0, 0, 0, 0xBB, 0x80, 0, 0] + child)
    }

    private func videoEntry(_ type: String, child: [UInt8]) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 78) + child)
    }

    private func tkhd(width: Int, height: Int) -> [UInt8] {
        full("tkhd", [UInt8](repeating: 0, count: 72) + be32(width << 16) + be32(height << 16))
    }

    private func initSegment(entry: [UInt8], tkhd: [UInt8] = []) -> [UInt8] {
        let stsd = full("stsd", be32(1) + entry)
        let trak = box("trak", tkhd + box("mdia", box("minf", box("stbl", stsd))))
        return box("ftyp", Array("isom".utf8) + be32(0)) + box("moov", trak)
    }

    // dec3: 5.1 = acmod 7 (3/2), lfeon 1
    private func dec3(acmod: Int, lfe: Int, joc: Int? = nil) -> [UInt8] {
        // data_rate(13)=640, num_ind_sub(3)=0
        var out: [UInt8] = [UInt8((640 >> 5) & 255), UInt8((640 & 31) << 3)]
        // fscod=0 bsid=16 (5 bits) reserved=0 | asvc=0 bsmod=0 acmod lfeon reserved=0 num_dep=0 reserved=0
        let bits = (0 << 22) | (16 << 17) | (0 << 16) | (0 << 15) | (0 << 12) | (acmod << 9) | (lfe << 8) | (0 << 5) | (0 << 1) | 0
        out += [UInt8(bits >> 16 & 255), UInt8(bits >> 8 & 255), UInt8(bits & 255)]
        if let joc { out += [0x01, UInt8(joc)] }
        return box("dec3", out)
    }

    private func dac3(acmod: Int, lfe: Int) -> [UInt8] {
        let b0 = (0 << 6) | (8 << 1) | 0              // fscod 0, bsid 8, bsmod high bit 0
        let b1 = (0 << 6) | (acmod << 3) | (lfe << 2) // bsmod low 2 bits, acmod, lfeon, brc high 2
        return box("dac3", [UInt8(b0), UInt8(b1), 0x00])
    }

    private func esds(channelConfig: Int) -> [UInt8] {
        // AudioSpecificConfig: aot 2 (5 bits), freq idx 3 (4 bits = 48k), channels (4 bits), 3 pad bits
        let asc = (2 << 11) | (3 << 7) | (channelConfig << 3)
        let dsi: [UInt8] = [5, 2, UInt8(asc >> 8), UInt8(asc & 255)]
        let dcd: [UInt8] = [4, UInt8(13 + dsi.count), 0x40, 0x15, 0, 0, 0] + be32(0) + be32(0) + dsi
        let es: [UInt8] = [3, UInt8(3 + dcd.count), 0, 1, 0] + dcd
        return full("esds", es)
    }

    // MARK: harness

    private func parse(_ bytes: [UInt8]) throws -> [[String: Any]] {
        let ctx = try XCTUnwrap(JSContext())
        ctx.exceptionHandler = { _, e in XCTFail("js: \(String(describing: e))") }
        ctx.evaluateScript("var globalThis = this; var top = this; var document = { addEventListener: function () {} };")
        ctx.evaluateScript(MediaProbeScript.source)
        let fn = try XCTUnwrap(ctx.evaluateScript("(function (a) { return JSON.stringify(__cmProbe.parse(new Uint8Array(a))); })"))
        let json = try XCTUnwrap(fn.call(withArguments: [bytes.map { Int($0) }])?.toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    // MARK: tests

    func testEAC3FiveOneWithoutAtmos() throws {
        let r = try parse(initSegment(entry: audioEntry("ec-3", child: dec3(acmod: 7, lfe: 1))))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0]["kind"] as? String, "audio")
        XCTAssertEqual(r[0]["codec"] as? String, "ec-3")
        XCTAssertEqual(r[0]["channels"] as? Int, 6)
        XCTAssertEqual(r[0]["joc"] as? Bool, false)
    }

    func testEAC3WithJOCExtensionIsFlagged() throws {
        let r = try parse(initSegment(entry: audioEntry("ec-3", child: dec3(acmod: 7, lfe: 1, joc: 16))))
        XCTAssertEqual(r[0]["channels"] as? Int, 6)
        XCTAssertEqual(r[0]["joc"] as? Bool, true)
        XCTAssertEqual(r[0]["jocComplexity"] as? Int, 16)
    }

    func testEAC3Stereo() throws {
        let r = try parse(initSegment(entry: audioEntry("ec-3", child: dec3(acmod: 2, lfe: 0))))
        XCTAssertEqual(r[0]["channels"] as? Int, 2)
    }

    func testAC3FiveOne() throws {
        let r = try parse(initSegment(entry: audioEntry("ac-3", child: dac3(acmod: 7, lfe: 1))))
        XCTAssertEqual(r[0]["codec"] as? String, "ac-3")
        XCTAssertEqual(r[0]["channels"] as? Int, 6)
    }

    func testAACStereo() throws {
        let r = try parse(initSegment(entry: audioEntry("mp4a", child: esds(channelConfig: 2))))
        XCTAssertEqual(r[0]["codec"] as? String, "mp4a")
        XCTAssertEqual(r[0]["channels"] as? Int, 2)
    }

    func testAACFiveOne() throws {
        let r = try parse(initSegment(entry: audioEntry("mp4a", child: esds(channelConfig: 6))))
        XCTAssertEqual(r[0]["channels"] as? Int, 6)
    }

    func testVideoCodecAndSizeFromTkhd() throws {
        let r = try parse(initSegment(entry: videoEntry("hvc1", child: box("hvcC", [1, 2, 3])), tkhd: tkhd(width: 3840, height: 2160)))
        XCTAssertEqual(r[0]["kind"] as? String, "video")
        XCTAssertEqual(r[0]["codec"] as? String, "hvc1")
        XCTAssertEqual(r[0]["width"] as? Int, 3840)
        XCTAssertEqual(r[0]["height"] as? Int, 2160)
    }

    func testDolbyVisionConfigFlagged() throws {
        let r = try parse(initSegment(entry: videoEntry("dvh1", child: box("hvcC", [1]) + box("dvcC", [1, 0])), tkhd: tkhd(width: 1920, height: 1080)))
        XCTAssertEqual(r[0]["dolbyVision"] as? Bool, true)
    }

    func testGarbageAndTruncatedGiveNoRecords() throws {
        XCTAssertEqual(try parse([1, 2, 3]).count, 0)
        XCTAssertEqual(try parse([0xFF, 0xFF, 0xFF, 0xFF, 0x6D, 0x6F, 0x6F, 0x76, 0, 0]).count, 0)
        let good = initSegment(entry: audioEntry("ec-3", child: dec3(acmod: 7, lfe: 1)))
        _ = try parse(Array(good.prefix(good.count - 6)))
    }

    func testManagedMediaSourceRecordsOnceAndRepeatInjectionDoesNotDoubleWrap() throws {
        let ctx = try XCTUnwrap(JSContext())
        ctx.exceptionHandler = { _, e in XCTFail("js: \(String(describing: e))") }
        ctx.evaluateScript("""
        var globalThis = this; var top = this; var document = { addEventListener: function () {} };
        globalThis.MediaSource = class { addSourceBuffer(m) { return new SourceBuffer(); } }
        globalThis.ManagedMediaSource = class extends MediaSource {}
        globalThis.SourceBuffer = class { appendBuffer(d) { this.n = (this.n || 0) + 1; } }
        globalThis.ManagedSourceBuffer = class extends SourceBuffer {}
        """)
        ctx.evaluateScript(MediaProbeScript.source)
        ctx.evaluateScript(MediaProbeScript.source)
        let bytes = initSegment(entry: audioEntry("ec-3", child: dec3(acmod: 7, lfe: 1))).map { Int($0) }
        ctx.setObject(bytes, forKeyedSubscript: "init" as NSString)
        let out = try XCTUnwrap(ctx.evaluateScript("""
        var sb = new globalThis.ManagedMediaSource().addSourceBuffer('audio/mp4;codecs=ec-3');
        sb.appendBuffer(new Uint8Array(init).buffer);
        JSON.stringify({ count: __cmProbe.buffers.length, channels: __cmProbe.buffers[0].parsed[0].channels, appended: sb.n });
        """)?.toString())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Int])
        XCTAssertEqual(obj["count"], 1)
        XCTAssertEqual(obj["channels"], 6)
        XCTAssertEqual(obj["appended"], 1)
    }
}
