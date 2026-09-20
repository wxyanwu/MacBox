import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class DanmakuBindingStoreTests: XCTestCase {
    func testBindingIsIndependentFromHistoryAndCanBeUpdated() async throws {
        let store = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let identity = editionIdentity()
        var binding = DanmakuBinding(
            editionIdentity: identity,
            locator: StableDanmakuLocator(
                kind: .providerEpisode,
                provider: "catpaw",
                resourceID: "episode-1",
                displayName: "来源一"
            ),
            offset: 0.5,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.saveDanmakuBinding(binding)
        let saved = try await store.danmakuBinding(for: identity)
        XCTAssertEqual(saved, binding)

        binding.offset = -1.25
        try await store.saveDanmakuBinding(binding)
        let updated = try await store.danmakuBinding(for: identity)
        XCTAssertEqual(updated?.offset, -1.25)
        let history = try await store.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testDeleteByConfigurationKeepsOtherBindings() async throws {
        let store = try SQLiteStore(databaseURL: temporaryDatabaseURL())
        let first = editionIdentity(configurationID: UUID())
        let second = editionIdentity(configurationID: UUID())
        for identity in [first, second] {
            try await store.saveDanmakuBinding(DanmakuBinding(
                editionIdentity: identity,
                locator: StableDanmakuLocator(
                    kind: .providerEpisode,
                    provider: "test",
                    resourceID: identity.episode.episodeID,
                    displayName: "测试"
                )
            ))
        }

        try await store.deleteDanmakuBindings(
            configurationID: first.episode.content.configurationID
        )

        let firstConfigurationBindings = try await store.danmakuBindings(
            configurationID: first.episode.content.configurationID
        )
        let secondConfigurationBindings = try await store.danmakuBindings(
            configurationID: second.episode.content.configurationID
        )
        let deleted = try await store.danmakuBinding(for: first)
        let preserved = try await store.danmakuBinding(for: second)
        XCTAssertTrue(firstConfigurationBindings.isEmpty)
        XCTAssertEqual(secondConfigurationBindings.count, 1)
        XCTAssertNil(deleted)
        XCTAssertNotNil(preserved)
    }

    private func editionIdentity(
        configurationID: UUID = UUID()
    ) -> DanmakuEditionIdentity {
        let content = DanmakuContentIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show"
        )
        return DanmakuEditionIdentity(
            episode: DanmakuEpisodeIdentity(
                content: content,
                episodeID: "episode",
                title: "第 1 集"
            ),
            editionID: "line"
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("test.sqlite")
    }
}
