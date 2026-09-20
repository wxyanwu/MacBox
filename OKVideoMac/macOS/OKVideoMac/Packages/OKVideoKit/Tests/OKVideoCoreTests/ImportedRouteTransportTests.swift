import Foundation
import XCTest
@testable import OKVideoCore

final class ImportedRouteTransportTests: XCTestCase {
    private func stream(_ name: String = "Main", url: String = "https://fixture.invalid/a?token=SECRET_TOKEN_DO_NOT_PERSIST",
                        headers: [String: String] = [:], format: String? = nil, parse: Bool = false) -> LiveStream {
        LiveStream(name: name, url: URL(string: url)!, headers: headers, format: format, needsParsing: parse)
    }
    private func native() throws -> LiveStream {
        let locator = try XtreamLivePlaybackLocator(providerID: UUID(), streamID: "42", outputFormat: .ts)
        return try LiveStream(name: "Native", target: .provider(.xtreamLive(locator)))
    }
    func testExactTupleEqual() { XCTAssertTrue(ImportedRouteTransport.same(stream(), stream())) }
    func testNameIsNotTransport() { XCTAssertTrue(ImportedRouteTransport.same(stream("A"), stream("B"))) }
    func testDifferentHeadersPreserved() {
        XCTAssertFalse(ImportedRouteTransport.same(stream(headers: ["Cookie": "A"]), stream(headers: ["Cookie": "B"])))
    }
    func testDictionaryOrderDoesNotMatter() {
        var a: [String: String] = [:], b: [String: String] = [:]
        a["X"] = "1"; a["Y"] = "2"; b["Y"] = "2"; b["X"] = "1"
        XCTAssertTrue(ImportedRouteTransport.same(stream(headers: a), stream(headers: b)))
    }
    func testHeaderCaseAndWhitespaceNotNormalized() {
        XCTAssertFalse(ImportedRouteTransport.same(stream(headers: ["X": "a"]), stream(headers: ["x": "a"])))
        XCTAssertFalse(ImportedRouteTransport.same(stream(headers: ["X": "a"]), stream(headers: ["X": " a"])))
    }
    func testHeaderValueUnicodeBytesNotNormalized() {
        XCTAssertFalse(ImportedRouteTransport.same(stream(headers: ["X": "é"]), stream(headers: ["X": "e\u{301}"])))
    }
    func testFormatNilEmptyAndValuesDistinct() {
        XCTAssertEqual(Set([stream(), stream(format: ""), stream(format: "ts"), stream(format: "TS")].compactMap(ImportedRouteTransport.init)).count, 4)
    }
    func testParsingFlagDistinct() { XCTAssertFalse(ImportedRouteTransport.same(stream(), stream(parse: true))) }
    func testQueryOrderAndPercentEncodingPreserved() {
        XCTAssertFalse(ImportedRouteTransport.same(stream(url: "https://fixture.invalid/a?x=1&y=2"), stream(url: "https://fixture.invalid/a?y=2&x=1")))
        XCTAssertFalse(ImportedRouteTransport.same(stream(url: "https://fixture.invalid/a%2Fb"), stream(url: "https://fixture.invalid/a/b")))
    }
    func testDedupePreservesFirstLabelAndRouteOrder() {
        let a = stream("First"), b = stream("Variant", headers: ["X": "1"])
        XCTAssertEqual(ImportedRouteTransport.deduplicated([a, b, stream("Alias")]), [a, b])
    }
    func testPermutationPreservesEquivalenceClasses() {
        let values = [stream(), stream("Alias"), stream(headers: ["X": "1"]), stream(parse: true)]
        let expected = Set(ImportedRouteTransport.deduplicated(values).compactMap(ImportedRouteTransport.init))
        for offset in values.indices {
            let reordered = Array(values[offset...] + values[..<offset])
            XCTAssertEqual(Set(ImportedRouteTransport.deduplicated(reordered).compactMap(ImportedRouteTransport.init)), expected)
        }
    }
    func testNativeNotGivenImportedEquality() throws {
        let n = try native()
        XCTAssertNil(ImportedRouteTransport(n)); XCTAssertFalse(ImportedRouteTransport.same(n, n))
        XCTAssertEqual(ImportedRouteTransport.deduplicated([n, n]), [n, n])
    }
    func testSameContextRepeatedLookupStable() throws {
        let a = stream(), c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [a]))
        let key = try XCTUnwrap(c.key(for: a))
        for _ in 0..<100 { XCTAssertEqual(c.key(for: stream("Other label")), key) }
        XCTAssertEqual(c.resolve(key), a); XCTAssertEqual(c.count, 1)
    }
    func testDifferentTuplesDifferentKeys() throws {
        let values = [stream(), stream(headers: ["X": "1"]), stream(format: "ts"), stream(parse: true)]
        let c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: values))
        XCTAssertEqual(Set(values.compactMap(c.key)).count, 4)
    }
    func testSameSourceNewContextRejectsOldKey() throws {
        let source = LiveSourceID.imported(UUID()), value = stream()
        let a = try XCTUnwrap(ImportedRouteContext(source: source, streams: [value]))
        let b = try XCTUnwrap(ImportedRouteContext(source: source, streams: [value]))
        let old = try XCTUnwrap(a.key(for: value)), new = try XCTUnwrap(b.key(for: value))
        XCTAssertNotEqual(old, new); XCTAssertNil(b.resolve(old)); XCTAssertNil(a.resolve(new))
        XCTAssertEqual(a.resolve(old), value)
    }
    func testDifferentSourcesRejectKeys() throws {
        let a = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [stream()]))
        let b = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [stream()]))
        XCTAssertNil(b.resolve(try XCTUnwrap(a.key(for: stream()))))
    }
    func testUnknownTransportCannotAllocateByLookup() throws {
        let c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [stream()]))
        XCTAssertNil(c.key(for: stream(headers: ["X": "new"])))
        XCTAssertNil(c.bindings(in: [stream(headers: ["X": "new"])])); XCTAssertEqual(c.count, 1)
    }
    func testEmptyContextValidButNativeNamespaceRejected() {
        XCTAssertEqual(ImportedRouteContext(source: .imported(UUID()), streams: [])?.count, 0)
        XCTAssertNil(ImportedRouteContext(source: .xtream(UUID()), streams: []))
    }
    func testProviderTargetRejectedEvenInImportedNamespace() throws {
        XCTAssertNil(ImportedRouteContext(source: .imported(UUID()), streams: [stream(), try native()]))
    }
    func testBindingsPreserveChannelSpecificLabelsWithoutNewIdentity() throws {
        let c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [stream("First channel")]))
        let bindings = try XCTUnwrap(c.bindings(in: [stream("Second channel"), stream("Alias")]))
        XCTAssertEqual(bindings.count, 1); XCTAssertEqual(bindings[0].stream.name, "Second channel")
        XCTAssertEqual(bindings[0].id, c.key(for: stream()))
    }
    func testContextOwnsImmutableTransportSnapshot() throws {
        var value = stream()
        let c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [value]))
        let key = try XCTUnwrap(c.key(for: value))
        value.headers["X"] = "changed"
        XCTAssertNil(c.key(for: value)); XCTAssertEqual(c.resolve(key), stream())
    }
    func testSessionCanRetainOldContextAfterBrowserReplacement() throws {
        let source = LiveSourceID.imported(UUID())
        var browser = try XCTUnwrap(ImportedRouteContext(source: source, streams: [stream()]))
        var session: ImportedRouteContext? = browser
        weak var old = browser
        let key = try XCTUnwrap(browser.key(for: stream()))
        browser = try XCTUnwrap(ImportedRouteContext(source: source, streams: [stream()]))
        XCTAssertNotNil(old); XCTAssertNotNil(session?.resolve(key)); XCTAssertNil(browser.resolve(key))
        session = nil; XCTAssertNil(old)
    }
    func testDescriptionsAndDumpDoNotExposeSecrets() throws {
        let value = stream(headers: ["Authorization": "SECRET_TOKEN_DO_NOT_PERSIST", "Cookie": "SECRET_TOKEN_DO_NOT_PERSIST"])
        let c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [value]))
        let key = try XCTUnwrap(c.key(for: value)), tuple = try XCTUnwrap(ImportedRouteTransport(value))
        var output = "\(c) \(key) \(tuple) \(String(reflecting: c))"
        dump(c, to: &output); dump(tuple, to: &output); dump(try XCTUnwrap(c.bindings(in: [value])), to: &output)
        for secret in ["SECRET_TOKEN", "fixture.invalid", "Authorization", "Cookie"] { XCTAssertFalse(output.contains(secret)) }
    }
    func testRuntimeTypesAreNotCodableAndStreamEncodingUnchanged() throws {
        let value = stream(), before = try JSONEncoder().encode(value)
        let c = try XCTUnwrap(ImportedRouteContext(source: .imported(UUID()), streams: [value]))
        XCTAssertFalse((c as Any) is any Encodable)
        XCTAssertFalse((try XCTUnwrap(c.key(for: value)) as Any) is any Encodable)
        XCTAssertFalse((try XCTUnwrap(ImportedRouteTransport(value)) as Any) is any Encodable)
        XCTAssertEqual(try JSONDecoder().decode(LiveStream.self, from: before), value)
        XCTAssertEqual(value.id, value.url?.absoluteString)
    }
}
