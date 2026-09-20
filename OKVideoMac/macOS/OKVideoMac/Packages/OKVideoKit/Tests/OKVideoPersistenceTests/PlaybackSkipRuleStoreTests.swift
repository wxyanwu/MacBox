import XCTest
@testable import OKVideoCore
@testable import OKVideoPersistence

final class PlaybackSkipRuleStoreTests: XCTestCase {
    func testRulesPersistSeparatelyFromHistoryAndSupportEpisodeOverride() async throws {
        let fixture = try Fixture()
        let configurationID = UUID()
        let lineIdentity = PlaybackSkipRuleIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            lineID: "line"
        )
        let episodeIdentity = PlaybackSkipRuleIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            lineID: "line",
            episodeID: "episode-2"
        )
        try await fixture.store.savePlaybackSkipRule(
            PlaybackSkipRule(
                identity: lineIdentity,
                opening: .enabled(90),
                ending: .enabled(60)
            )
        )
        try await fixture.store.savePlaybackSkipRule(
            PlaybackSkipRule(
                identity: episodeIdentity,
                opening: .disabled,
                ending: .inherited
            )
        )

        let rules = try await fixture.store.playbackSkipRules(
            configurationID: configurationID
        )
        XCTAssertEqual(rules.count, 2)
        let effective = PlaybackSkipRuleResolver.resolve(
            line: rules.first { $0.identity == lineIdentity },
            episode: rules.first { $0.identity == episodeIdentity }
        )
        XCTAssertEqual(
            effective,
            EffectivePlaybackSkipRule(
                openingEnd: nil,
                endingDuration: 60
            )
        )

        _ = try await fixture.store.deleteHistory(
            configurationID: configurationID
        )
        let rulesAfterHistoryDeletion = try await fixture.store
            .playbackSkipRules(configurationID: configurationID)
        XCTAssertEqual(
            rulesAfterHistoryDeletion.count,
            2
        )
    }

    func testInheritedOnlyRuleDeletesStoredOverride() async throws {
        let fixture = try Fixture()
        let identity = PlaybackSkipRuleIdentity(
            configurationID: UUID(),
            siteKey: "site",
            contentID: "show",
            lineID: "line",
            episodeID: "episode"
        )
        try await fixture.store.savePlaybackSkipRule(
            PlaybackSkipRule(
                identity: identity,
                opening: .disabled
            )
        )
        try await fixture.store.savePlaybackSkipRule(
            PlaybackSkipRule(identity: identity)
        )

        let rules = try await fixture.store.playbackSkipRules(
            configurationID: identity.configurationID
        )
        XCTAssertTrue(rules.isEmpty)
    }

    func testCompletionMarkerIsIndependentAndCanBeClearedWithHistoryID() async throws {
        let fixture = try Fixture()
        let configurationID = UUID()
        let identity = PlaybackSkipRuleIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            lineID: "line",
            episodeID: "episode-7"
        )
        try await fixture.store.savePlaybackCompletionMarker(
            PlaybackCompletionMarker(
                identity: identity,
                historyRecordID: "history-7",
                position: 2_610,
                duration: 2_700
            )
        )
        let stored = try await fixture.store.playbackCompletionMarkers(
            configurationID: configurationID
        )
        XCTAssertEqual(stored.first?.position, 2_610)

        try await fixture.store.deletePlaybackCompletionMarkers(
            historyRecordIDs: ["history-7"]
        )
        let remaining = try await fixture.store.playbackCompletionMarkers(
            configurationID: configurationID
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    private final class Fixture {
        let directory: URL
        let store: SQLiteStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            store = try SQLiteStore(
                databaseURL: directory.appendingPathComponent("test.sqlite3")
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
