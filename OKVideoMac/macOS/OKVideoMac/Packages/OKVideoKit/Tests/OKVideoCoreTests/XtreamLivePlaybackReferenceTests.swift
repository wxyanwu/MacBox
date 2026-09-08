import XCTest
@testable import OKVideoCore

final class XtreamLivePlaybackReferenceTests: XCTestCase {
    private let providerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testLegacyEpisodeWireFormatRemainsUnchangedIncludingReplayVersions() throws {
        for version in [1, 2, 7] {
            for stability in ["providerStable", "providerReplay"] {
                let original: [String: Any] = [
                    "schemaVersion": version,
                    "configurationIdentity": "legacy-config",
                    "siteIdentity": "legacy-site",
                    "providerKind": "legacy-provider",
                    "providerVersion": 3,
                    "stableResourceLocator": "resource.42",
                    "sourceIdentity": "source.1",
                    "episodeIdentity": "episode.42",
                    "stability": stability,
                    "expiresAt": 123.0
                ]
                let originalData = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
                let reference = try JSONDecoder().decode(PlaybackResourceReference.self, from: originalData)
                XCTAssertEqual(reference.resourceKind, .episode)
                XCTAssertNil(reference.xtreamLiveLocator)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                XCTAssertEqual(try encoder.encode(reference), originalData)
                XCTAssertFalse(try object(reference).keys.contains("resourceKind"))
            }
        }
    }

    func testLegacyInitializerAndPersistenceRulesRemainEpisodeOnly() throws {
        var legacy = PlaybackResourceReference(
            schemaVersion: 7,
            configurationIdentity: "config",
            siteIdentity: "site",
            providerKind: "provider",
            providerVersion: 2,
            stableResourceLocator: "resource.1",
            sourceIdentity: "source.1",
            episodeIdentity: "episode.1",
            stability: .providerStable
        )
        XCTAssertEqual(legacy.resourceKind, .episode)
        XCTAssertEqual(PlaybackPersistencePolicy.sanitizedProviderResourceReference(legacy), legacy)
        legacy.stability = .providerReplay
        XCTAssertNil(PlaybackPersistencePolicy.sanitizedProviderResourceReference(legacy))
        XCTAssertEqual(try JSONDecoder().decode(PlaybackResourceReference.self, from: JSONEncoder().encode(legacy)), legacy)
    }

    func testLiveLocatorCanonicalRoundTripAndIndependentFormat() throws {
        let ts = try locator()
        XCTAssertEqual(ts.version, 1)
        XCTAssertEqual(ts.encoded, "xtr1.l.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.31303031.ts")
        XCTAssertEqual(try XtreamLivePlaybackLocator(encoded: ts.encoded), ts)
        XCTAssertEqual(try JSONDecoder().decode(XtreamLivePlaybackLocator.self, from: JSONEncoder().encode(ts)), ts)
        let hls = try locator(format: .m3u8)
        XCTAssertEqual(hls.providerID, ts.providerID)
        XCTAssertEqual(hls.streamID, ts.streamID)
        XCTAssertNotEqual(hls.encoded, ts.encoded)
        XCTAssertEqual(try XtreamLivePlaybackLocator(encoded: hls.encoded), hls)
    }

    func testLiveLocatorRejectsMalformedOrNonCanonicalEncoding() throws {
        let valid = try locator().encoded
        let invalid = [
            valid.replacingOccurrences(of: "xtr1", with: "xtr2"),
            valid.replacingOccurrences(of: ".l.", with: ".m."),
            valid.replacingOccurrences(of: ".ts", with: ".mp4"),
            valid.replacingOccurrences(of: ".ts", with: ".TS"),
            valid.replacingOccurrences(of: "aaaaaaaa", with: "AAAAAAAA"),
            valid.replacingOccurrences(of: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", with: "not-a-uuid"),
            valid.replacingOccurrences(of: "31303031", with: ""),
            valid.replacingOccurrences(of: "31303031", with: "313"),
            valid.replacingOccurrences(of: "31303031", with: "zz"),
            valid.replacingOccurrences(of: "31303031", with: "ff"),
            valid + ".extra",
            "https://example.invalid/live/user/pass/1001.ts"
        ]
        for value in invalid {
            XCTAssertThrowsError(try XtreamLivePlaybackLocator(encoded: value))
        }
        for streamID in ["", " ", "a b", "a\nb", "..", "a/b", "a\\b", "a?b", "a#b", "a%b", "https:example.invalid", String(repeating: "1", count: 513)] {
            XCTAssertThrowsError(try XtreamLivePlaybackLocator(providerID: providerID, streamID: streamID, outputFormat: .ts))
        }
        _ = try XtreamLivePlaybackLocator(providerID: providerID, streamID: String(repeating: "1", count: 512), outputFormat: .ts)
        for (key, value) in [("version", 2 as Any), ("outputFormat", "mp4"), ("streamID", "https://example.invalid")] {
            var json = try object(locator())
            json[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(XtreamLivePlaybackLocator.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testLiveReferenceHasExplicitKindAndNoEpisodeOrCredentialFields() throws {
        let locator = try locator()
        let reference = PlaybackResourceReference.xtreamLive(locator)
        XCTAssertEqual(reference.schemaVersion, 2)
        XCTAssertEqual(reference.resourceKind, .live)
        XCTAssertEqual(reference.xtreamLiveLocator, locator)
        XCTAssertEqual(reference.sourceIdentity, "")
        XCTAssertEqual(reference.episodeIdentity, "")
        let json = try object(reference)
        XCTAssertEqual(Set(json.keys), Set([
            "schemaVersion", "resourceKind", "configurationIdentity", "siteIdentity",
            "providerKind", "providerVersion", "stableResourceLocator", "stability"
        ]))
        XCTAssertEqual(json["resourceKind"] as? String, "live")
        let data = try JSONEncoder().encode(reference)
        let serialized = String(decoding: data, as: UTF8.self)
        for forbidden in ["sourceIdentity", "episodeIdentity", "username", "password", "http", "expiresAt"] {
            XCTAssertFalse(serialized.contains(forbidden))
        }
        XCTAssertEqual(try JSONDecoder().decode(PlaybackResourceReference.self, from: data), reference)
        XCTAssertEqual(PlaybackPersistencePolicy.sanitizedProviderResourceReference(reference), reference)
    }

    func testEpisodeCodecPreservesOldKeysAndOptionalNullBehavior() throws {
        let minimal = Data(#"{"name":"Episode","url":"episode.1"}"#.utf8)
        let withNulls = Data(#"{"name":"Episode","url":"episode.1","referenceIdentity":null,"providerResourceReference":null}"#.utf8)
        let first = try JSONDecoder().decode(PlayEpisode.self, from: minimal)
        let second = try JSONDecoder().decode(PlayEpisode.self, from: withNulls)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(try object(first).keys), Set(["name", "url"]))

        let reference = PlaybackResourceReference(
            configurationIdentity: "config", siteIdentity: "site",
            providerKind: "provider", providerVersion: 1,
            stableResourceLocator: "resource.1", sourceIdentity: "source.1",
            episodeIdentity: "episode.1", stability: .providerStable
        )
        let episode = PlayEpisode(name: "Episode", url: "episode.1", referenceIdentity: "episode.1", providerResourceReference: reference)
        let data = try JSONEncoder().encode(episode)
        XCTAssertEqual(try JSONDecoder().decode(PlayEpisode.self, from: data), episode)
        XCTAssertEqual(Set(try object(episode).keys), Set(["name", "url", "referenceIdentity", "providerResourceReference"]))
    }

    func testEpisodeCodecRejectsLiveReferenceWithoutAdaptingIt() throws {
        let reference = PlaybackResourceReference.xtreamLive(try locator())
        let episode = PlayEpisode(name: "Not an episode", url: "opaque", providerResourceReference: reference)
        XCTAssertThrowsError(try JSONEncoder().encode(episode))
        let json: [String: Any] = [
            "name": "Not an episode", "url": "opaque",
            "providerResourceReference": try object(reference)
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(PlayEpisode.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertNil(SpiderResponseMapper.providerPlaybackResourceDescriptor(.object([
            "providerResourceReference": .object([
                "schemaVersion": .number(2), "resourceKind": .string("live"),
                "providerVersion": .number(1), "stability": .string("providerStable"),
                "stableResourceLocator": .string(reference.stableResourceLocator)
            ])
        ])))
    }

    func testLiveReferenceDecoderRejectsWrongVersionKindBindingAndLegacySlots() throws {
        let reference = PlaybackResourceReference.xtreamLive(try locator())
        let original = try object(reference)
        let invalid: [(String, Any)] = [
            ("schemaVersion", 1), ("schemaVersion", 3),
            ("resourceKind", "unknown"), ("resourceKind", "episode"),
            ("providerKind", "other"), ("providerVersion", 2),
            ("configurationIdentity", UUID().uuidString.lowercased()),
            ("siteIdentity", "other-site"), ("stability", "providerReplay"),
            ("expiresAt", 123), ("sourceIdentity", ""),
            ("episodeIdentity", ""), ("sourceIdentity", NSNull()),
            ("stableResourceLocator", reference.stableResourceLocator + ".extra")
        ]
        for (key, value) in invalid {
            var json = original
            json[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(PlaybackResourceReference.self, from: JSONSerialization.data(withJSONObject: json)), "Must reject \(key)")
        }
        var untagged = original
        untagged.removeValue(forKey: "resourceKind")
        XCTAssertThrowsError(try JSONDecoder().decode(PlaybackResourceReference.self, from: JSONSerialization.data(withJSONObject: untagged)))
    }

    func testMutatedLiveReferenceCannotCrossEncodingOrPersistenceBoundary() throws {
        let reference = PlaybackResourceReference.xtreamLive(try locator())
        let mutations: [(inout PlaybackResourceReference) -> Void] = [
            { $0.schemaVersion = 1 },
            { $0.providerVersion = 2 },
            { $0.configurationIdentity = UUID().uuidString.lowercased() },
            { $0.siteIdentity = "wrong-site" },
            { $0.providerKind = "wrong-provider" },
            { $0.stability = .providerReplay },
            { $0.expiresAt = Date() },
            { $0.sourceIdentity = "legacy-source" },
            { $0.episodeIdentity = "legacy-episode" },
            { $0.stableResourceLocator = "https://example.invalid/live/user/pass/1001.ts" }
        ]
        for mutate in mutations {
            var invalid = reference
            mutate(&invalid)
            XCTAssertNil(invalid.xtreamLiveLocator)
            XCTAssertNil(PlaybackPersistencePolicy.sanitizedProviderResourceReference(invalid))
            XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        }
    }

    func testMovieProviderRejectsLiveReferencesAndLocators() async throws {
        let provider = try XtreamSiteProvider(
            configuration: XtreamProviderConfiguration(
                providerID: providerID,
                displayName: "Fixture",
                serverBaseURL: XCTUnwrap(URL(string: "https://example.invalid"))
            ),
            credentials: XtreamCredentials(username: "fixture-user", password: "fixture"),
            httpClient: NoRequestLiveReferenceHTTPClient(),
            userAgent: "Tests"
        )
        let locator = try locator()
        let reference = PlaybackResourceReference.xtreamLive(locator)
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(reference))
        var disguised = reference
        disguised.resourceKind = .episode
        disguised.schemaVersion = 1
        disguised.sourceIdentity = "source.1"
        disguised.episodeIdentity = "episode.1"
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(disguised))
        do {
            _ = try await provider.player(flag: "Live", episodeURL: locator.encoded)
            XCTFail("Live must not enter the Movie/Series API")
        } catch {
            XCTAssertEqual(error as? XtreamSiteProviderError, .invalidPlaybackLocator)
        }
        do {
            _ = try await provider.refreshPlayback(PlaybackRefreshRequest(
                videoID: "xtr.movie.31303031",
                title: "Not a Live episode",
                sourceIdentity: "",
                resourceIdentity: "",
                providerResourceReference: reference
            ))
            XCTFail("Live must not enter the default episode refresh selection")
        } catch {
            XCTAssertEqual(error as? AppError, .playback("Live references cannot use episode playback refresh."))
        }
    }

    private func locator(format: XtreamLiveOutputFormat = .ts) throws -> XtreamLivePlaybackLocator {
        try XtreamLivePlaybackLocator(providerID: providerID, streamID: "1001", outputFormat: format)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}

private struct NoRequestLiveReferenceHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTFail("Reference validation must not issue any network request")
        throw HTTPClientError.cancelled
    }
}
