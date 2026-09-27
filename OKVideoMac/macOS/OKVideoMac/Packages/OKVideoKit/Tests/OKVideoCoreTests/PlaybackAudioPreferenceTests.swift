import XCTest
@testable import OKVideoCore

final class PlaybackAudioPreferenceTests: XCTestCase {
    @MainActor
    func testZeroMuteAndAmplificationSurviveStoreRecreation() throws {
        let suite = "OKVideoAudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for volume in [0.0, 35, 100, 120, 130] {
            let store = PlaybackAudioPreferenceStore(defaults: defaults)
            store.setVolume(volume)
            store.setMuted(true)
            XCTAssertEqual(PlaybackAudioPreferenceStore(defaults: defaults).value, .init(volume: volume, muted: true))
            store.setMuted(false)
            XCTAssertEqual(PlaybackAudioPreferenceStore(defaults: defaults).value, .init(volume: volume, muted: false))
        }
    }

    @MainActor
    func testPositiveUserVolumeUnmutesButRestorationDoesNot() throws {
        let suite = "OKVideoAudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioPreferenceStore(defaults: defaults)
        store.setVolume(35)
        store.setMuted(true)
        XCTAssertTrue(PlaybackAudioPreferenceStore(defaults: defaults).value.muted)
        store.setVolume(0)
        XCTAssertTrue(store.value.muted)
        store.setVolume(35)
        XCTAssertFalse(store.value.muted)
        store.setMuted(true)
        store.setMuted(false)
        XCTAssertEqual(store.value.volume, 35)
    }

    @MainActor
    func testInvalidInputCannotEraseLastChoice() {
        let store = PlaybackAudioPreferenceStore()
        store.setVolume(35)
        store.setVolume(.nan)
        store.setVolume(.infinity)
        XCTAssertEqual(store.value.volume, 35)
        store.setVolume(-1)
        XCTAssertEqual(store.value.volume, 0)
        store.setVolume(500)
        XCTAssertEqual(store.value.volume, 130)
    }

    @MainActor
    func testRapidChangesSaveFinalIntentWithoutAsyncWork() throws {
        let suite = "OKVideoAudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioPreferenceStore(defaults: defaults)
        for value in 0...120 { store.setVolume(Double(value)) }
        XCTAssertEqual(PlaybackAudioPreferenceStore(defaults: defaults).value.volume, 120)
        XCTAssertGreaterThan(store.revision, 100)
    }
}
