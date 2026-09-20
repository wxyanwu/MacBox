import XCTest
@testable import OKVideoCore

final class HLSStartupSelectionTests: XCTestCase {
    private let base = URL(string: "https://cdn.example/dir/master.m3u8?master=secret")!
    private func master(count: Int = 12) -> String {
        var result = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English, stereo",URI="audio.m3u8?token=a%2Bb"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="../subs.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ac3",NAME="Other",URI="other.m3u8"
        """ + "\n"
        for n in 1...count {
            result += "#EXT-X-STREAM-INF:BANDWIDTH=\(n * 1000),RESOLUTION=1920x1080,CODECS=\"avc1.64002a,mp4a.40.2\",AUDIO=\"aac\",SUBTITLES=\"subs\"\nvideo\(n).m3u8?sig=x%2Fy\n"
        }
        return result
    }
    func testPreservesMatchingAudioSubtitlesAndSignedRelativeURIs() throws {
        let result = try XCTUnwrap(HLSStartupSelection.select(from: Data(master().utf8), baseURL: base))
        XCTAssertEqual(result.routingURL.absoluteString, "https://cdn.example/dir/video12.m3u8?sig=x%2Fy")
        XCTAssertTrue(result.playlist.contains("audio.m3u8?token=a%2Bb"))
        XCTAssertTrue(result.playlist.contains("https://cdn.example/subs.m3u8"))
        XCTAssertTrue(result.playlist.contains("NAME=\"English, stereo\""))
        XCTAssertFalse(result.playlist.contains("other.m3u8"))
        XCTAssertFalse(result.playlist.contains("master=secret"))
        XCTAssertEqual(result.playlist.components(separatedBy: "#EXT-X-STREAM-INF:").count, 2)
    }
    func testSmallMastersAreSelectedButSingleAndMediaPlaylistsStayOriginal() throws {
        let selected = try XCTUnwrap(HLSStartupSelection.select(from: Data(master(count: 5).utf8), baseURL: base))
        XCTAssertEqual(selected.variantCount, 5)
        XCTAssertTrue(selected.routingURL.path.hasSuffix("video5.m3u8"))
        XCTAssertNil(HLSStartupSelection.select(from: Data(master(count: 1).utf8), baseURL: base))
        XCTAssertNil(HLSStartupSelection.select(from: Data("#EXTM3U\n#EXTINF:5,\na.ts\n".utf8), baseURL: base))
    }
    func testMissingAudioGroupUnknownExtensionsAndInvalidAttributesDeclineSelection() {
        for text in [master().replacingOccurrences(of: "AUDIO=\"aac\"", with: "AUDIO=\"missing\""),
                     master() + "#EXT-X-DEFINE:NAME=\"x\",VALUE=\"y\"\n",
                     master() + "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"\n",
                     master().replacingOccurrences(of: "BANDWIDTH=1000,", with: "BANDWIDTH=1000,BANDWIDTH=2000,"),
                     master().replacingOccurrences(of: "mp4a.40.2", with: "unknown-codec")] {
            XCTAssertNil(HLSStartupSelection.select(from: Data(text.utf8), baseURL: base))
        }
    }
    func testMissingCodecDeclarationsPreserveSelectedVariantAndGroups() throws {
        let text = master(count: 6).replacingOccurrences(of: ",CODECS=\"avc1.64002a,mp4a.40.2\"", with: "")
        let selected = try XCTUnwrap(HLSStartupSelection.select(from: Data(text.utf8), baseURL: base))
        XCTAssertTrue(selected.routingURL.path.hasSuffix("video6.m3u8"))
        XCTAssertTrue(selected.playlist.contains("audio.m3u8?token=a%2Bb"))
        XCTAssertFalse(selected.playlist.contains("CODECS="))
    }
    func testHEVCAndSurroundAudioDoNotForce1080pDowngrade() throws {
        let text = master(count: 2).replacingOccurrences(of: "1920x1080", with: "3840x2160")
            .replacingOccurrences(of: "avc1.64002a,mp4a.40.2", with: "hvc1.2.4.L153.B0,ec-3")
        let selected = try XCTUnwrap(HLSStartupSelection.select(from: Data(text.utf8), baseURL: base))
        XCTAssertTrue(selected.playlist.contains("3840x2160"))
        XCTAssertTrue(selected.playlist.contains("ec-3"))
        XCTAssertTrue(selected.playlist.contains("audio.m3u8"))
    }
    func testUnsupportedHigherQualityKeepsOriginalInsteadOfDowngrading() {
        let text = master(count: 2) + "#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,CODECS=\"unknown-video,mp4a.40.2\"\nother.m3u8\n"
        XCTAssertNil(HLSStartupSelection.select(from: Data(text.utf8), baseURL: base))
    }
    func testRejectsOversizedAndUnsafeManifests() {
        let prefix = master()
        let boundedPrefix = prefix + String(repeating: " ", count: 256 * 1024 - prefix.utf8.count)
        XCTAssertNil(HLSStartupSelection.select(from: Data(boundedPrefix.utf8), baseURL: base))
        XCTAssertNil(HLSStartupSelection.select(from: Data(repeating: 65, count: 256 * 1024 + 1), baseURL: base))
        XCTAssertNil(HLSStartupSelection.select(from: Data(master().replacingOccurrences(of: "video1.m3u8", with: "file:///private/file").utf8), baseURL: base))
        XCTAssertNil(HLSStartupSelection.select(from: Data((master() + "\0").utf8), baseURL: base))
    }
    func testExistingMediaDefaultsDoNotOptIntoCompatibility() {
        let media = ResolvedMedia(url: base, headers: [:], siteKey: "xtream-live", sourceName: "x", episodeName: "y")
        XCTAssertEqual(media.compatibilityPolicy, .existing)
        XCTAssertNil(media.hlsStartupSelection)
    }
}
