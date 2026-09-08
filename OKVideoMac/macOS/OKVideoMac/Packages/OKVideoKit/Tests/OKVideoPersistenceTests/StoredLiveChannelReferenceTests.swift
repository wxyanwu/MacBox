import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class StoredLiveChannelReferenceTests: XCTestCase {
    private let providerA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let providerB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testLegacyReferencesRoundTripWithoutSplittingOrNormalizing() throws {
        for identifier in [
            "Source::With::Separators::Group::Name",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA::Group::Channel",
            "  Source::Group::Channel  ",
            ""
        ] {
            let reference = StoredLiveChannelReference(setting: .string(identifier))
            XCTAssertEqual(reference, .legacy(identifier))
            let data = try JSONEncoder().encode(reference)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), identifier)
        }
    }

    func testXtreamReferencesAreVersionedAndProviderScoped() throws {
        let reference = StoredLiveChannelReference.xtream(providerID: providerA, streamID: "42")
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reference))
        XCTAssertEqual(value, .object([
            "version": .integer(1), "kind": .string("xtream"),
            "providerID": .string(providerA.uuidString.lowercased()), "streamID": .string("42")
        ]))
        XCTAssertEqual(StoredLiveChannelReference(setting: value), reference)
        XCTAssertNotEqual(reference, .xtream(providerID: providerB, streamID: "42"))
        let object = try XCTUnwrap(value.objectValue)
        for forbidden in ["name", "url", "headers", "format", "password", "username", "categoryID"] {
            XCTAssertNil(object[forbidden])
        }
    }

    func testUnknownMalformedAndExtendedObjectsRemainOpaque() throws {
        let values: [JSONValue] = [
            .object(["version": .integer(2), "kind": .string("xtream"), "future": .array([.integer(9)])]),
            .object(["version": .integer(1), "kind": .string("other")]),
            .object(["version": .integer(1), "kind": .string("xtream"), "providerID": .string("bad"), "streamID": .string("42")]),
            .object(["version": .integer(1), "kind": .string("xtream"), "providerID": .string(providerA.uuidString), "streamID": .string("42"), "future": .bool(true)]),
            .null, .bool(false), .array([.string("future")])
        ]
        for value in values {
            let reference = StoredLiveChannelReference(setting: value)
            XCTAssertEqual(reference, .unsupported(value))
            XCTAssertEqual(
                try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reference)), value
            )
        }
    }

    func testNativeMembershipEditsPreserveLegacyAndUnknownMembers() throws {
        let legacy = JSONValue.string("Source::Group::One")
        let unknown = JSONValue.object(["version": .integer(9), "keep": .string("untouched")])
        let other = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            StoredLiveChannelReference.xtream(providerID: providerB, streamID: "42")
        ))
        var envelope = StoredLiveChannelReferenceEnvelope(setting: .array([legacy, unknown, other]))
        try envelope.setXtream(providerID: providerA, streamID: "42", isIncluded: true)
        XCTAssertTrue(envelope.containsXtream(providerID: providerA, streamID: "42"))
        XCTAssertTrue(envelope.containsXtream(providerID: providerB, streamID: "42"))
        let once = envelope.setting
        try envelope.setXtream(providerID: providerA, streamID: "42", isIncluded: true)
        XCTAssertEqual(envelope.setting, once)
        try envelope.setXtream(providerID: providerA, streamID: "42", isIncluded: false)
        XCTAssertEqual(envelope.setting, .array([legacy, unknown, other]))
    }

    func testUnknownRootIsReadOnlyAndNeverReplacedByKnownSubset() {
        for original in [JSONValue.object(["version": .integer(7), "items": .array([])]), .null, .string("future")] {
            var envelope = StoredLiveChannelReferenceEnvelope(setting: original)
            XCTAssertTrue(envelope.isReadOnly)
            XCTAssertThrowsError(try envelope.setXtream(providerID: providerA, streamID: "42", isIncluded: true))
            XCTAssertEqual(envelope.setting, original)
        }
    }

    func testInvalidNativeReferenceCannotBeEncodedOrAdded() {
        for streamID in ["", "https://user:password@example.invalid/live", "../42", "42?token=secret"] {
            let reference = StoredLiveChannelReference.xtream(providerID: providerA, streamID: streamID)
            XCTAssertThrowsError(try JSONEncoder().encode(reference))
            var envelope = StoredLiveChannelReferenceEnvelope(setting: nil)
            XCTAssertThrowsError(try envelope.setXtream(providerID: providerA, streamID: streamID, isIncluded: true))
            XCTAssertEqual(envelope.setting, .array([]))
        }
    }
}
