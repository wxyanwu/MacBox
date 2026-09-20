import XCTest
@testable import OKVideoCore

final class EPGPreferenceTests: XCTestCase {
    let id = UUID()
    let embedded = URL(string: "https://example.invalid/embedded.xml")!
    func prefs(_ mode: EPGSourceMode = .automatic) -> EPGPreferences {
        EPGPreferences(defaultEPGURL: "https://example.invalid/global.xml.gz",
            sources: [id.uuidString: EPGSourcePreference(mode: mode, customEPGURL: "https://example.invalid/custom")])
    }
    func testCustomWinsAndNeverFallsBack() {
        XCTAssertEqual(prefs(.custom).resolvedXMLTV(for: .imported(id), embedded: embedded)?.origin, .custom)
        var invalid = prefs(.custom)
        invalid.sources[id.uuidString]?.customEPGURL = "invalid"
        XCTAssertNil(invalid.resolvedXMLTV(for: .imported(id), embedded: embedded))
        XCTAssertThrowsError(try invalid.validated())
    }
    func testEmbeddedWinsOverGlobal() {
        XCTAssertEqual(prefs().resolvedXMLTV(for: .imported(id), embedded: embedded)?.url, embedded)
    }
    func testMissingEmbeddedUsesGlobalAndEmptyGlobalMeansNone() {
        XCTAssertEqual(prefs().resolvedXMLTV(for: .imported(id), embedded: nil)?.origin, .global)
        XCTAssertNil(EPGPreferences().resolvedXMLTV(for: .imported(id), embedded: nil))
    }
    func testDisabledAndMasterSwitchSuppressSources() {
        XCTAssertNil(prefs(.disabled).resolvedXMLTV(for: .imported(id), embedded: embedded))
        var value = prefs(.custom); value.automaticEPGEnabled = false
        XCTAssertNil(value.resolvedXMLTV(for: .imported(id), embedded: embedded))
    }
    func testNativeNeverUsesExternalXMLTV() {
        XCTAssertNil(prefs(.custom).resolvedXMLTV(for: .xtream(id), embedded: embedded))
    }
    func testGlobalChangesOnlyAffectGlobalConsumers() {
        for mode in [EPGSourceMode.automatic, .custom] {
            var value = prefs(mode)
            let previous = value.resolvedXMLTV(for: .imported(id), embedded: embedded)
            value.defaultEPGURL = nil
            XCTAssertEqual(previous, value.resolvedXMLTV(for: .imported(id), embedded: embedded))
        }
        var value = prefs()
        let previous = value.resolvedXMLTV(for: .imported(id), embedded: nil)
        value.defaultEPGURL = "https://example.invalid/new.xml"
        XCTAssertNotEqual(previous?.revision, value.resolvedXMLTV(for: .imported(id), embedded: nil)?.revision)
        value.defaultEPGURL = nil
        XCTAssertNil(value.resolvedXMLTV(for: .imported(id), embedded: nil))
    }
    func testHistoricalMissingFieldsDefaultToAutomatic() throws {
        let value = try JSONDecoder().decode(EPGPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(value.automaticEPGEnabled)
        XCTAssertEqual(value.source(id).mode, .automatic)
        XCTAssertEqual(value.resolvedXMLTV(for: .imported(id), embedded: embedded)?.url, embedded)
        XCTAssertEqual(try JSONDecoder().decode(EPGSourcePreference.self, from: Data("{}".utf8)).mode, .automatic)
    }
    func testURLValidationAllowsQueryWithoutRequiringExtension() throws {
        XCTAssertNotNil(try EPGPreferences.validatedURL("https://example.invalid/api?token=fixture"))
        XCTAssertNil(try EPGPreferences.validatedURL("  "))
        for invalid in ["file:///tmp/epg.xml", "javascript:alert(1)", "https://", "https://example.invalid/a b"] {
            XCTAssertThrowsError(try EPGPreferences.validatedURL(invalid))
        }
    }
    func testHeaderAliasesAndDeterministicPrecedence() throws {
        func parse(_ header: String) throws -> URL? {
            try LiveSourceParser().parse(Data(("#EXTM3U " + header + "\n#EXTINF:-1,CCTV-1\nhttps://example.invalid/live\n").utf8)).epgURL
        }
        XCTAssertEqual(try parse(#"x-tvg-url="https://example.invalid/x.xml.gz""#)?.path, "/x.xml.gz")
        for fields in [
            #"x-tvg-url="https://example.invalid/x" url-tvg="https://example.invalid/u" tvg-url="https://example.invalid/t""#,
            #"tvg-url="https://example.invalid/t" x-tvg-url="https://example.invalid/x" url-tvg="https://example.invalid/u""#
        ] { XCTAssertEqual(try parse(fields)?.path, "/t") }
        XCTAssertEqual(try parse(#"tvg-url="" url-tvg="https://example.invalid/u" x-tvg-url="https://example.invalid/x""#)?.path, "/u")
    }
}
