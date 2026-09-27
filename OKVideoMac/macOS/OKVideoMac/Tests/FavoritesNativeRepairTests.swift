import AppKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

private actor FavoriteFixtureData {
    var title = "Film"
    var delay: UInt64 = 0
    func set(title: String, delay: UInt64 = 0) { self.title = title; self.delay = delay }
    func get() async throws -> String { try await Task.sleep(nanoseconds: delay); return title }
}
private struct FavoriteFixtureProvider: SiteProvider {
    let data: FavoriteFixtureData
    let site = SiteConfiguration(key: "favorite-fixture", name: "Fixture Provider", type: 1, api: "https://example.invalid/api")
    let capability = SiteCapability.standardJSON
    func home() async throws -> SiteHome { .init(categories: [], recommendations: []) }
    func category(id: String, page: Int, filters: [String: String]) async throws -> VideoPage { .init(items: [], pagination: .init(page: page, pageCount: 0)) }
    func search(keyword: String, page: Int, quick: Bool) async throws -> VideoPage { try await category(id: keyword, page: page, filters: [:]) }
    func player(flag: String, episodeURL: String) async throws -> SitePlaybackResult { throw AppError.site("fixture") }
    func detail(id: String) async throws -> VideoDetail {
        .init(summary: .init(siteKey: site.key, siteName: site.name, videoID: id, title: try await data.get(), year: "2026"), synopsis: "Fixture synopsis", playSources: [])
    }
}

@MainActor final class FavoritesNativeRepairTests: XCTestCase {
    private func fixture() async throws -> (AppState, AppEnvironment, StoredConfiguration, FavoriteFixtureProvider, VideoDetail) {
        let environment = try AppEnvironment.live()
        let provider = FavoriteFixtureProvider(data: FavoriteFixtureData())
        let state = AppState(environment: environment)
        let record = StoredConfiguration(name: "A", sourceKind: .pasted, rawData: try JSONEncoder().encode(FongMiConfiguration(sites: [provider.site])))
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: try await provider.home())
        let detail = try await provider.detail(id: "same")
        await state.loadDetail(detail.summary)
        return (state, environment, record, provider, detail)
    }
    func testStarIsScopedAndExplicitRepeatedSetIsIdempotent() async throws {
        let (state, _, a, provider, detail) = try await fixture()
        await state.setFavorite(detail, isFavorite: true)
        await state.setFavorite(detail, isFavorite: true)
        XCTAssertEqual(state.favorites.count, 1); XCTAssertTrue(state.isFavorite(detail))
        var b = a; b.id = UUID(); b.name = "B"
        state.seedCategoryHomeForTesting(record: b, provider: provider, home: try await provider.home())
        await state.loadDetail(detail.summary)
        XCTAssertFalse(state.isFavorite(detail))
        await state.setFavorite(detail, isFavorite: true)
        XCTAssertEqual(state.favorites.count, 2)
        await state.setFavorite(detail, isFavorite: false)
        XCTAssertEqual(state.favorites.count, 1); XCTAssertEqual(state.favorites[0].configurationID, a.id)
    }
    func testConcurrentIdenticalIntentsDoNotToggleBackOff() async throws {
        let (state, _, _, _, detail) = try await fixture()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await state.setFavorite(detail, isFavorite: true) } }
        }
        XCTAssertEqual(state.favorites.count, 1)
        XCTAssertTrue(state.favoritePendingIdentities.isEmpty)
        await state.setFavorite(detail, isFavorite: false)
        await state.setFavorite(detail, isFavorite: false)
        XCTAssertTrue(state.favorites.isEmpty)
    }
    func testKnownSourceOpenVerifiesBothCacheAndNetwork() async throws {
        let (state, _, record, provider, detail) = try await fixture()
        await state.setFavorite(detail, isFavorite: true)
        let favorite = try XCTUnwrap(state.favorites.first)
        // The source exists in the fixture even though startup's list is empty.
        state.seedFavoriteConfigurationsForTesting([record])
        await state.openFavorite(favorite)
        XCTAssertEqual(state.selectedDetail?.summary.title, "Film")
        state.dismissDetail()
        await provider.data.set(title: "Different Film")
        await state.loadDetail(detail.summary, forceRefresh: true)
        XCTAssertEqual(state.selectedDetail?.summary.title, "Different Film")
        state.dismissDetail()
        await state.openFavorite(favorite)
        XCTAssertNil(state.selectedDetail, "cached wrong work must be rejected")
        XCTAssertEqual(state.favorites.first?.title, "Film")
        await state.refreshDetail()
        XCTAssertNil(state.selectedDetail, "network wrong work must also be rejected")
        XCTAssertEqual(state.favorites.count, 1)
    }
    func testDeleteWhileOpeningCannotRecreateFavorite() async throws {
        let (state, environment, record, provider, detail) = try await fixture()
        await state.setFavorite(detail, isFavorite: true)
        let favorite = try XCTUnwrap(state.favorites.first)
        state.seedFavoriteConfigurationsForTesting([record])
        state.dismissDetail()
        state.seedCategoryHomeForTesting(record: record, provider: provider, home: try await provider.home())
        await provider.data.set(title: "Film", delay: 100_000_000)
        let opening = Task { await state.openFavorite(favorite) }
        try await Task.sleep(nanoseconds: 15_000_000)
        let deleted = await state.deleteFavorites(ids: [favorite.id])
        XCTAssertTrue(deleted)
        await opening.value
        let stored = try await environment.database.favorites()
        XCTAssertTrue(stored.isEmpty); XCTAssertTrue(state.favorites.isEmpty)
        XCTAssertNil(state.favoriteLoadingID)
    }
    func testSourceRenameKeepsFingerprintButServerChangeDoesNot() async throws {
        let (_, _, record, provider, _) = try await fixture()
        let context = FavoriteSourceContext(configuration: record, site: provider.site)
        var renamed = record; renamed.name = "Renamed"; renamed.updatedAt = Date().addingTimeInterval(1)
        var site = provider.site; site.name = "Renamed provider"
        XCTAssertEqual(FavoriteSourceContext(configuration: renamed, site: site).fingerprint, context.fingerprint)
        site.api = "https://other.example.invalid"
        XCTAssertNotEqual(FavoriteSourceContext(configuration: renamed, site: site).fingerprint, context.fingerprint)
    }
    func testPortableV4IncludesFavoritesAndV3LeavesFieldAbsent() async throws {
        let (_, _, configuration, _, detail) = try await fixture()
        let favorite = FavoriteRecord(siteKey: detail.summary.siteKey, videoID: "same", title: "Film", createdAt: Date(timeIntervalSince1970: 1_700_000_000), configurationID: configuration.id)
        let encoded = try PortableBackupCodec.encode(configuration: configuration, history: [], favorites: [favorite], appVersion: "test", appBuild: "121")
        let result = try PortableBackupCodec.decode(encoded)
        XCTAssertEqual(result.manifest.favoriteCount, 1); XCTAssertEqual(result.payload.favorites, [favorite])
        var envelope = try JSONDecoder.backupDates.decode(PortableBackupEnvelope.self, from: encoded)
        var payload = try JSONSerialization.jsonObject(with: envelope.payload) as! [String: Any]
        payload.removeValue(forKey: "favorites")
        envelope.payload = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        envelope.payloadSHA256 = PortableBackupCodec.sha256Hex(envelope.payload)
        envelope.manifest.schemaVersion = 3; envelope.manifest.favoriteCount = nil
        let old = try PortableBackupCodec.decode(JSONEncoder.backupDates.encode(envelope))
        XCTAssertNil(old.payload.favorites)
    }
    func testPortableRejectsCrossConfigurationFavoriteAndRuntimeLocator() async throws {
        let (_, _, configuration, _, _) = try await fixture()
        let wrong = FavoriteRecord(siteKey: "s", videoID: "a", title: "A", configurationID: UUID())
        XCTAssertThrowsError(try PortableBackupCodec.encode(configuration: configuration, history: [], favorites: [wrong], appVersion: "test", appBuild: "121"))
        XCTAssertFalse(FavoritePersistencePolicy.isSafeLocator("http://127.0.0.1:1234/media"))
        XCTAssertFalse(FavoritePersistencePolicy.isSafeLocator("https://example.org/video?token=private"))
        XCTAssertTrue(FavoritePersistencePolicy.isSafeLocator("https://example.org/share/123"))
    }
}
private extension JSONDecoder { static var backupDates: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value } }
private extension JSONEncoder { static var backupDates: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .millisecondsSince1970; return value } }
