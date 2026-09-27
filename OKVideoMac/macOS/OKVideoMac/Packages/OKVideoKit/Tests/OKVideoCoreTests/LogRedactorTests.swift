import XCTest
@testable import OKVideoCore

final class LogRedactorTests: XCTestCase {
    func testQuarkCapabilityURLsAndStandaloneCredentialsAreRedacted() throws {
        let samples = [
            "https://dl-pc-sz.drive.quark.cn/opaque-path-secret/video?auth_key=signed-secret&ork=ork-secret&unknown=capability-secret",
            "http://127.0.0.1:9000/proxy/quark/encoded-share-secret/file-secret/down?opaque=capability-secret",
            "request /proxy/quark/encoded-share-secret/file-secret/down?opaque=capability-secret failed",
            "__puus=rotating-secret; __pus=login-secret; __uid=identity-secret auth_key=signed-secret ork=ork-secret"
        ]
        for sample in samples {
            let result = LogRedactor.text(sample)
            XCTAssertFalse(result.contains("-secret"), result)
            XCTAssertTrue(result.contains("redacted"))
        }
        let object = LogRedactor.json(["auth_key": "signed-secret", "__puus": "rotating-secret", "ork": "ork-secret"]) as? [String: String]
        XCTAssertEqual(object?.values.filter { $0 == "<redacted>" }.count, 3)
    }

    func testQuarkRedactionPreservesUnrelatedMediaPaths() throws {
        let original = "https://media.example.invalid/posters/movie.jpg?page=2"
        XCTAssertEqual(LogRedactor.url(try XCTUnwrap(URL(string: original))), original)
        let redacted = LogRedactor.url(try XCTUnwrap(URL(string: "http://localhost:8080/proxy/quark/opaque-secret")))
        XCTAssertFalse(redacted.contains("opaque-secret"))
        XCTAssertTrue(redacted.contains("/proxy/quark/"))
    }
    func testURLRedactsUserInfoWithoutQueryItems() throws {
        let url = try XCTUnwrap(
            URL(string: "https://account:password@example.invalid/index.js.md5")
        )

        let redacted = LogRedactor.url(url)

        XCTAssertFalse(redacted.contains("account"))
        XCTAssertFalse(redacted.contains("password"))
        XCTAssertTrue(redacted.contains("example.invalid/index.js.md5"))
    }

    func testURLRedactsSensitiveQueryAndUserInfoTogether() throws {
        let url = try XCTUnwrap(
            URL(
                string: "https://user:secret@example.invalid/config"
                    + "?token=value&mode=full"
            )
        )

        let redacted = LogRedactor.url(url)

        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("value"))
        XCTAssertTrue(redacted.contains("mode=full"))
    }

    func testURLRedactsXtreamQueryCredentials() throws {
        let url = try XCTUnwrap(
            URL(
                string: "https://example.invalid/player_api.php"
                    + "?username=account-name&password=secret&action=get_vod_streams"
            )
        )

        let redacted = LogRedactor.url(url)

        XCTAssertFalse(redacted.contains("account-name"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("action=get_vod_streams"))
    }

    func testURLRedactsXtreamPlaybackPathCredentials() throws {
        for route in ["live", "movie", "series", "timeshift"] {
            let url = try XCTUnwrap(
                URL(
                    string: "https://example.invalid/prefix/\(route)"
                        + "/account-name/secret/12345.m3u8"
                )
            )

            let redacted = LogRedactor.url(url)

            XCTAssertFalse(redacted.contains("account-name"), route)
            XCTAssertFalse(redacted.contains("secret"), route)
            XCTAssertTrue(redacted.contains("12345.m3u8"), route)
        }
    }

    func testTextRedactsStandaloneXtreamCredentialAssignments() {
        let redacted = LogRedactor.text(
            "username=account-name password=secret-value action=auth"
        )

        XCTAssertFalse(redacted.contains("account-name"))
        XCTAssertFalse(redacted.contains("secret-value"))
        XCTAssertTrue(redacted.contains("action=auth"))
    }

    func testHeadersRedactAuthenticationAndCookieValues() {
        let redacted = LogRedactor.headers([
            "Authorization": "Bearer super-secret",
            "Cookie": "session=private",
            "Accept": "application/json"
        ])

        XCTAssertEqual(redacted["Authorization"], "<redacted>")
        XCTAssertEqual(redacted["Cookie"], "<redacted>")
        XCTAssertEqual(redacted["Accept"], "application/json")
    }

    func testNestedJSONAndFreeFormTextAreSanitized() throws {
        let object: [String: Any] = [
            "site": "fixture",
            "nested": [
                "token": "nested-secret",
                "url": "http://user:pass@example.invalid/a?stoken=query-secret"
            ]
        ]
        let data = try XCTUnwrap(LogRedactor.jsonData(
            try JSONSerialization.data(withJSONObject: object)
        ))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("nested-secret"))
        XCTAssertFalse(text.contains("query-secret"))
        XCTAssertFalse(text.contains("user"))
        XCTAssertFalse(text.contains("pass"))
        XCTAssertTrue(text.contains("fixture"))

        let line = LogRedactor.text(
            "Authorization: Bearer abc123\npath=/Users/alice/Library/cache token=xyz"
        )
        XCTAssertFalse(line.contains("abc123"))
        XCTAssertFalse(line.contains("alice"))
        XCTAssertFalse(line.contains("xyz"))
        XCTAssertTrue(line.contains("<HOME>"))
    }
}
