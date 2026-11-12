import XCTest
@testable import CouchModeCore

/// Expected outputs frozen from the former built-in Swift readers, stored as JSON in `Fixtures/golden/<service>-<what>.json`.
/// A file holds one entry per comparison a test makes, in order. Everything in them is synthetic fixture content.
final class Golden {
    private let service: String
    private let function: String
    private var index = 0
    private var cache: [Any]?

    /// `service` is the file prefix; `function` is the test's name (the `<what>` part).
    init(_ service: String, function: String = #function) {
        self.service = service
        // An XCTestCase's `name` is "-[Class testName]"; `#function` is "testName()".
        var f = function.split(separator: " ").last.map(String.init) ?? function
        if f.hasSuffix("]") { f.removeLast() }
        if f.hasSuffix("()") { f.removeLast(2) }
        if f.hasPrefix("test"), f.count > 4 { f = f.dropFirst(4).prefix(1).lowercased() + f.dropFirst(5) }
        self.function = f
    }

    private var name: String { "\(service)-\(function)" }

    private func entries() throws -> [Any] {
        if let cache { return cache }
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/golden"), "no golden file \(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])
        let list = try XCTUnwrap(object as? [Any])
        cache = list
        return list
    }

    /// The next frozen result as JSON (`NSNull` for "the reader returned nothing").
    func next(file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        let list = try entries()
        XCTAssertLessThan(index, list.count, "\(name): golden has no entry \(index)", file: file, line: line)
        defer { index += 1 }
        return index < list.count ? list[index] : NSNull()
    }

    /// Whether the next frozen result is "nothing" (nil).
    func nextIsNil(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let value = try next(file: file, line: line)
        return value is NSNull
    }

    /// Compares `actual` (any decoded value) with the next frozen result.
    func expect(_ actual: Any?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try next(file: file, line: line)
        let got = Golden.json(actual as Any)
        XCTAssertTrue(Golden.equal(got, expected), "\(name)[\(index - 1)] \(message)\nexpected \(Golden.text(expected))\n     got \(Golden.text(got))", file: file, line: line)
    }

    /// `actual` (a decoded value) against a frozen result from `next()`.
    static func assertEqual(_ actual: Any?, _ expected: Any, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let got = json(actual as Any)
        XCTAssertTrue(equal(got, expected), "\(message)\nexpected \(text(expected))\n     got \(text(got))", file: file, line: line)
    }

    static func equal(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    static func text(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "?" }
        let s = String(decoding: data, as: UTF8.self)
        return s.count > 600 ? String(s.prefix(600)) + "..." : s
    }

    /// A value's stored properties as JSON (structs as objects, enums by case, optionals as null, URLs as text).
    static func json(_ value: Any) -> Any {
        if let url = value as? URL { return url.absoluteString }
        if value is NSNull { return NSNull() }
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i }
        if let d = value as? Double { return d }
        if let s = value as? String { return s }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional: return mirror.children.first.map { json($0.value) } ?? NSNull()
        case .collection, .set: return mirror.children.map { json($0.value) }
        case .dictionary:
            var out: [String: Any] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                if pair.count == 2 { out["\(pair[0].value)"] = json(pair[1].value) }
            }
            return out
        case .enum:
            if mirror.children.isEmpty { return "\(value)" }
            return ["case": mirror.children.first?.label ?? "", "value": mirror.children.first.map { json($0.value) } ?? NSNull()] as [String: Any]
        case .struct, .class, .tuple:
            var out: [String: Any] = [:]
            for (i, child) in mirror.children.enumerated() { out[child.label ?? "\(i)"] = json(child.value) }
            return out
        default: return "\(value)"
        }
    }
}
