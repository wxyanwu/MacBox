import Foundation
import XCTest
@testable import OKVideoCore
@testable import OKVideoPersistence

final class EPGGuideXtreamLoaderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_789_862_400)

    func testPerRowTokensAndShortCoverageSemanticsRemainExplicit() async throws {
        let directory = cacheDirectory()
        let repository = EPGProductionRepository(cacheDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LiveSourceID.xtream(UUID())
        let revision = "xtream-revision"
        let channels = (0..<5).map {
            LiveChannel(groupName: "", name: "Channel \($0)", streams: [],
                        explicitID: "row-\($0)")
        }
        let demandRevision = UUID()
        let demand = try guideDemand(source: source, revision: revision,
            demandRevision: demandRevision, channels: channels, hours: 24)
        let context = EPGGuideXtreamContext(
            accountIdentity: "account",
            serverIdentity: "https://provider.invalid",
            configurationRevision: revision,
            streamIDByChannelID: [
                "row-0": "100",
                "row-1": "101",
                "row-2": "102",
                "row-3": "103"
            ]
        )
        let counts = XtreamFetchProbe()
        let snapshot = try await EPGGuideXtreamLoader.load(
            repository: repository,
            demand: demand,
            context: context,
            fetch: { [start] streamID in
                await counts.begin(streamID)
                defer { Task { await counts.finish() } }
                switch streamID {
                case "100":
                    return EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
                        EPGProgramme(channelID: streamID, title: "Long",
                            start: start.addingTimeInterval(11 * 3_600),
                            end: start.addingTimeInterval(13 * 3_600)),
                        EPGProgramme(channelID: streamID, title: "Later",
                            start: start.addingTimeInterval(14 * 3_600),
                            end: start.addingTimeInterval(15 * 3_600))
                    ]))
                case "101":
                    return EPGPayload(guide: XMLTVGuide(channels: [], programmes: []),
                                      unsupported: true)
                case "102":
                    return EPGPayload(guide: XMLTVGuide(channels: [], programmes: []))
                default:
                    return EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
                        EPGProgramme(channelID: streamID, title: "Outside",
                            start: start.addingTimeInterval(48 * 3_600),
                            end: start.addingTimeInterval(49 * 3_600))
                    ]))
                }
            }
        )

        XCTAssertEqual(snapshot.coherence, .perRowToken)
        XCTAssertEqual(snapshot.rows[0].programmes.map(\.title), ["Long", "Later"])
        XCTAssertEqual(snapshot.rows[0].programmes.map(\.id.ordinal), [0, 1])
        XCTAssertEqual(snapshot.rows[0].state, .ready)
        XCTAssertEqual(snapshot.rows[1].state, .unsupported)
        XCTAssertEqual(snapshot.rows[2].state, .empty)
        XCTAssertEqual(snapshot.rows[3].state, .unsupported)
        XCTAssertEqual(snapshot.rows[4].state, .unsupported)
        XCTAssertNil(snapshot.rows[4].token)
        XCTAssertTrue(snapshot.rows.compactMap(\.token).allSatisfy {
            $0.demandRevision == demandRevision
                && $0.serviceIncarnation == repository.incarnation
        })
        let fetchCounts = [
            await counts.count(for: "100"),
            await counts.count(for: "101"),
            await counts.count(for: "102"),
            await counts.count(for: "103")
        ]
        XCTAssertEqual(fetchCounts, [1, 1, 1, 1])
        let closed = await repository.close()
        XCTAssertTrue(closed)
    }

    func testAllDesiredRowsFinishWithAtMostFourConcurrentFetches() async throws {
        let directory = cacheDirectory()
        let repository = EPGProductionRepository(cacheDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LiveSourceID.xtream(UUID())
        let channels = (0..<20).map {
            LiveChannel(groupName: "", name: "Channel \($0)", streams: [],
                        explicitID: "row-\($0)")
        }
        let streamIDs = Dictionary(uniqueKeysWithValues: channels.enumerated().map {
            ($0.element.id, String(1_000 + $0.offset))
        })
        let demand = try guideDemand(source: source, revision: "r1",
            demandRevision: UUID(), channels: channels, hours: 12)
        let probe = XtreamFetchProbe()
        let snapshot = try await EPGGuideXtreamLoader.load(
            repository: repository,
            demand: demand,
            context: EPGGuideXtreamContext(accountIdentity: "account",
                serverIdentity: "server", configurationRevision: "r1",
                streamIDByChannelID: streamIDs),
            fetch: { [start] streamID in
                await probe.begin(streamID)
                try await Task.sleep(nanoseconds: 10_000_000)
                await probe.finish()
                return EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
                    EPGProgramme(channelID: streamID, title: "Programme \(streamID)",
                        start: start, end: start.addingTimeInterval(3_600))
                ]))
            }
        )

        XCTAssertEqual(snapshot.rows.count, channels.count)
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.state == .ready })
        let total = await probe.total
        let peakActive = await probe.peakActive
        XCTAssertEqual(total, channels.count)
        XCTAssertLessThanOrEqual(peakActive, EPGGuideLimits.maximumRunning)
        let closed = await repository.close()
        XCTAssertTrue(closed)
    }

    func testCancellingOneDemandDoesNotCancelSharedChannelFlight() async throws {
        let directory = cacheDirectory()
        let repository = EPGProductionRepository(cacheDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LiveSourceID.xtream(UUID())
        let channel = LiveChannel(groupName: "", name: "One", streams: [],
                                  explicitID: "row")
        let context = EPGGuideXtreamContext(accountIdentity: "account",
            serverIdentity: "server", configurationRevision: "r1",
            streamIDByChannelID: [channel.id: "7"])
        let probe = XtreamFetchProbe()
        let fetch: EPGGuideXtreamLoader.Fetch = { [start] streamID in
            await probe.begin(streamID)
            try await Task.sleep(nanoseconds: 80_000_000)
            await probe.finish()
            return EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
                EPGProgramme(channelID: streamID, title: "Shared",
                    start: start, end: start.addingTimeInterval(3_600))
            ]))
        }
        let firstDemand = try guideDemand(source: source, revision: "r1",
            demandRevision: UUID(), channels: [channel], hours: 12)
        let secondDemand = try guideDemand(source: source, revision: "r1",
            demandRevision: UUID(), channels: [channel], hours: 12)
        let first = Task {
            try await EPGGuideXtreamLoader.load(repository: repository,
                demand: firstDemand, context: context, fetch: fetch)
        }
        while await probe.total == 0 { await Task.yield() }
        let second = Task {
            try await EPGGuideXtreamLoader.load(repository: repository,
                demand: secondDemand, context: context, fetch: fetch)
        }
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("cancelled demand returned a snapshot")
        } catch {
            XCTAssertEqual(error as? EPGGuideFailure, .cancelled)
        }
        let snapshot = try await second.value
        XCTAssertEqual(snapshot.rows[0].programmes.first?.title, "Shared")
        let total = await probe.total
        XCTAssertEqual(total, 1)
        let closed = await repository.close()
        XCTAssertTrue(closed)
    }

    private func guideDemand(source: LiveSourceID, revision: String,
                             demandRevision: UUID, channels: [LiveChannel],
                             hours: Int) throws -> EPGGuideDemand {
        let boundary = min(12, hours)
        var slices = [try EPGGuideTimeSlice(start: start,
            end: start.addingTimeInterval(Double(boundary) * 3_600))]
        if hours > 12 {
            slices.append(try EPGGuideTimeSlice(
                start: start.addingTimeInterval(12 * 3_600),
                end: start.addingTimeInterval(Double(hours) * 3_600)
            ))
        }
        return try EPGGuideDemand(source: EPGSourceKey(source), revision: revision,
            demandRevision: demandRevision, capability: .xtreamShort,
            channels: channels, visibleRange: 0..<channels.count, slices: slices)
    }

    private func cacheDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp/EPGCache-Guide-Xtream-" + UUID().uuidString)
    }
}

private actor XtreamFetchProbe {
    private var counts: [String: Int] = [:]
    private var active = 0
    private(set) var peakActive = 0

    var total: Int { counts.values.reduce(0, +) }

    func count(for streamID: String) -> Int { counts[streamID, default: 0] }

    func begin(_ streamID: String) {
        counts[streamID, default: 0] += 1
        active += 1
        peakActive = max(peakActive, active)
    }

    func finish() { active = max(0, active - 1) }
}
