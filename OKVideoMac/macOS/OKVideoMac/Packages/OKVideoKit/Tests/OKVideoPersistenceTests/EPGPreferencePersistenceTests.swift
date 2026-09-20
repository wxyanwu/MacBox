import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class EPGPreferencePersistenceTests: XCTestCase {
    func testHistoricalStoreAndRoundTripDoNotChangeLiveSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(databaseURL: path)
        let source = StoredLiveSource(name: "Fixture", sourceKind: .pasted,
            rawData: Data("#EXTM3U\n#EXTINF:-1,CCTV-1\nhttps://example.invalid/stream".utf8))
        try await store.saveLiveSource(source)
        let old = try await store.epgPreferences()
        XCTAssertEqual(old.source(source.id).mode, .automatic)
        let configured = EPGPreferences(automaticEPGEnabled: false, defaultEPGURL: "https://example.invalid/global.xml",
            sources: [source.id.uuidString: EPGSourcePreference(mode: .custom, customEPGURL: "https://example.invalid/custom.xml.gz")])
        try await store.saveEPGPreferences(configured)
        let reopened = try SQLiteStore(databaseURL: path)
        let restored = try await reopened.epgPreferences()
        XCTAssertEqual(restored, configured)
        let sources = try await reopened.liveSources()
        XCTAssertEqual(sources.first?.rawData, source.rawData)
        var invalid = configured
        invalid.sources[source.id.uuidString]?.customEPGURL = "bad"
        do { try await store.saveEPGPreferences(invalid); XCTFail("Invalid custom saved") } catch {}
        let preserved = try await store.epgPreferences()
        XCTAssertEqual(preserved, configured)
    }
}
