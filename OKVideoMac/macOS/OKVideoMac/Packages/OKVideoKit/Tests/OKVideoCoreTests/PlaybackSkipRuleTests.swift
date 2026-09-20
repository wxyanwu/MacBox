import XCTest
@testable import OKVideoCore

final class PlaybackSkipRuleTests: XCTestCase {
    func testEpisodeFieldsOverrideOrInheritLineFieldsIndependently() {
        let line = PlaybackSkipRule(
            identity: identity(),
            opening: .enabled(92),
            ending: .enabled(65)
        )
        let episode = PlaybackSkipRule(
            identity: identity(episodeID: "episode-7"),
            opening: .disabled,
            ending: .inherited
        )

        XCTAssertEqual(
            PlaybackSkipRuleResolver.resolve(line: line, episode: episode),
            EffectivePlaybackSkipRule(
                openingEnd: nil,
                endingDuration: 65
            )
        )
    }

    func testStartPositionMergesResumeAndOpeningIntoOneTarget() {
        XCTAssertEqual(
            PlaybackSkipPolicy.startPosition(
                resumePosition: nil,
                openingEnd: 90,
                canSeek: true
            ),
            90
        )
        XCTAssertEqual(
            PlaybackSkipPolicy.startPosition(
                resumePosition: 30,
                openingEnd: 90,
                canSeek: true
            ),
            90
        )
        XCTAssertEqual(
            PlaybackSkipPolicy.startPosition(
                resumePosition: 600,
                openingEnd: 90,
                canSeek: true
            ),
            600
        )
        XCTAssertEqual(
            PlaybackSkipPolicy.startPosition(
                resumePosition: 30,
                openingEnd: 90,
                canSeek: false
            ),
            30
        )
    }

    func testValidationRejectsOversizedAndOverlappingRules() {
        XCTAssertEqual(
            PlaybackSkipPolicy.validated(
                EffectivePlaybackSkipRule(
                    openingEnd: 90,
                    endingDuration: 60
                ),
                duration: 2_700
            ),
            EffectivePlaybackSkipRule(
                openingEnd: 90,
                endingDuration: 60
            )
        )
        XCTAssertEqual(
            PlaybackSkipPolicy.validated(
                EffectivePlaybackSkipRule(
                    openingEnd: 250,
                    endingDuration: 20
                ),
                duration: 1_000
            ),
            EffectivePlaybackSkipRule(
                openingEnd: nil,
                endingDuration: 20
            )
        )
        XCTAssertTrue(
            PlaybackSkipPolicy.validated(
                EffectivePlaybackSkipRule(
                    openingEnd: 190,
                    endingDuration: 190
                ),
                duration: 400
            ).isEmpty
        )
    }

    func testEndingPromptLeadUsesWallClockSecondsAtPlaybackSpeed() {
        let boundary = PlaybackSkipPolicy.endingBoundary(
            duration: 2_700,
            endingDuration: 60
        )
        XCTAssertEqual(boundary, 2_640)
        XCTAssertEqual(
            PlaybackSkipPolicy.endingPromptStart(
                boundary: boundary!,
                speed: 1
            ),
            2_635
        )
        XCTAssertEqual(
            PlaybackSkipPolicy.endingPromptStart(
                boundary: boundary!,
                speed: 2
            ),
            2_630
        )
    }

    private func identity(
        episodeID: String? = nil
    ) -> PlaybackSkipRuleIdentity {
        PlaybackSkipRuleIdentity(
            configurationID: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!,
            siteKey: "site",
            contentID: "show",
            lineID: "line",
            episodeID: episodeID
        )
    }
}
