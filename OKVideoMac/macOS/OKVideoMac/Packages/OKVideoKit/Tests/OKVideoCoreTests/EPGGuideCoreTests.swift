import Foundation
import XCTest
@testable import OKVideoCore

final class EPGGuideCoreTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 2_000_000_000)

    func testDemandRejectsUnboundedRowsAndNonAdjacentSlices() throws {
        let slice = try EPGGuideTimeSlice(start: anchor,
            end: anchor.addingTimeInterval(12 * 60 * 60))
        XCTAssertThrowsError(try demand(count: 49, slices: [slice]))
        let separated = try EPGGuideTimeSlice(start: slice.end.addingTimeInterval(1),
            end: slice.end.addingTimeInterval(3_601))
        XCTAssertThrowsError(try demand(count: 2, slices: [slice, separated]))
    }

    func testCoordinatorRetainsAllDesiredRowsWhileBoundingQueueAndRunning() throws {
        var coordinator = try EPGGuideWorkCoordinator(demand: demand(count: 48))
        var seen = Set<Int>()
        var iterations = 0
        while !coordinator.isFinished {
            let assignments = coordinator.nextAssignments()
            XCTAssertFalse(assignments.isEmpty)
            XCTAssertLessThanOrEqual(assignments.count, EPGGuideLimits.maximumRunning)
            for assignment in assignments {
                seen.insert(assignment.id.channelIndex)
                try coordinator.completePage(assignment.id, acceptedProgrammes: 1,
                    acceptedBytes: 200, hasMore: false)
            }
            iterations += 1
            XCTAssertLessThan(iterations, 100)
        }
        XCTAssertEqual(seen, Set(0..<48))
        XCTAssertEqual(coordinator.metrics.completedRows, 48)
        XCTAssertLessThanOrEqual(coordinator.metrics.peakRunnable, 8)
        XCTAssertLessThanOrEqual(coordinator.metrics.peakRunning, 4)
    }

    func testFirstPagesAreFairBeforeOneRowContinuesPagination() throws {
        var coordinator = try EPGGuideWorkCoordinator(demand: demand(count: 12))
        var firstPageOrder: [Int] = []
        var firstSecondPagePosition: Int?
        var completionPosition = 0
        while !coordinator.isFinished {
            for assignment in coordinator.nextAssignments() {
                if assignment.pageIndex == 0 { firstPageOrder.append(assignment.id.channelIndex) }
                if assignment.pageIndex == 1, firstSecondPagePosition == nil {
                    firstSecondPagePosition = completionPosition
                }
                let more = assignment.id.channelIndex == 0 && assignment.pageIndex < 3
                try coordinator.completePage(assignment.id, acceptedProgrammes: 1,
                    acceptedBytes: 128, hasMore: more)
                completionPosition += 1
            }
        }
        XCTAssertEqual(Set(firstPageOrder), Set(0..<12))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstSecondPagePosition), 12)
    }

    func testOldSnapshotIsReleasedWhenItBlocksVisibleProgress() throws {
        var coordinator = try EPGGuideWorkCoordinator(demand: demand(count: 3),
            retainedSnapshotCost: 7 * 1_024 * 1_024)
        let assignments = coordinator.nextAssignments()
        XCTAssertTrue(coordinator.hasDroppedRetainedSnapshot)
        XCTAssertFalse(assignments.isEmpty)
    }

    func testRowAndGlobalLimitsTerminateWithoutRetryLoop() throws {
        var rowLimited = try EPGGuideWorkCoordinator(demand: demand(count: 1))
        for _ in 0..<4 {
            let assignment = try XCTUnwrap(rowLimited.nextAssignments().first)
            try rowLimited.completePage(assignment.id, acceptedProgrammes: 64,
                acceptedBytes: 64, hasMore: true)
        }
        XCTAssertEqual(rowLimited.terminalStates, [.truncated(.perRowLimit)])
        XCTAssertTrue(rowLimited.isFinished)

        var global = try EPGGuideWorkCoordinator(demand: demand(count: 48))
        var guardCount = 0
        while !global.isFinished {
            let assignments = global.nextAssignments()
            XCTAssertFalse(assignments.isEmpty)
            for assignment in assignments {
                try global.completePage(assignment.id, acceptedProgrammes: 64,
                    acceptedBytes: 64, hasMore: true)
            }
            guardCount += 1
            XCTAssertLessThan(guardCount, 200)
        }
        XCTAssertTrue(global.terminalStates.contains(.truncated(.globalItemLimit)))
    }

    func testSnapshotRejectsMixedXMLTVGenerationAndDuplicateRecordIdentity() throws {
        let source = EPGSourceKey(.imported(UUID()))
        let revision = String(repeating: "a", count: 64)
        let demandRevision = UUID()
        let token = EPGResultToken(serviceIncarnation: UUID(), resourceIdentity: "resource",
            sourceEpoch: revision, dataVersion: "g1", demandRevision: demandRevision)
        let other = EPGResultToken(serviceIncarnation: token.serviceIncarnation,
            resourceIdentity: token.resourceIdentity, sourceEpoch: token.sourceEpoch,
            dataVersion: "g2", demandRevision: demandRevision)
        let channel = EPGGuideChannel(live(0))
        let record = window(token: token, ordinal: 7)
        let valid = EPGGuideRow(channel: channel, token: token,
            match: EPGChannelMatch(kind: .exact, channelID: "c0"), availability: .fresh,
            programmes: [record], state: .ready)
        XCTAssertNoThrow(try EPGGuideSnapshot(source: source, revision: revision,
            demandRevision: demandRevision, slices: demand(count: 1).slices,
            coherence: .xmltv(token), rows: [valid]))

        let mixed = EPGGuideRow(channel: channel, token: other,
            match: EPGChannelMatch(kind: .exact, channelID: "c0"), availability: .fresh,
            programmes: [record], state: .ready)
        XCTAssertThrowsError(try EPGGuideSnapshot(source: source, revision: revision,
            demandRevision: demandRevision, slices: demand(count: 1).slices,
            coherence: .xmltv(token), rows: [mixed]))
        let duplicated = EPGGuideRow(channel: channel, token: token,
            match: EPGChannelMatch(kind: .exact, channelID: "c0"), availability: .fresh,
            programmes: [record, record], state: .ready)
        XCTAssertThrowsError(try EPGGuideSnapshot(source: source, revision: revision,
            demandRevision: demandRevision, slices: demand(count: 1).slices,
            coherence: .xmltv(token), rows: [duplicated]))
    }

    func testDeterministicCostCountsUTF8AndRejectsOverBudgetSnapshot() throws {
        let token = EPGResultToken(serviceIncarnation: UUID(), resourceIdentity: "r",
            sourceEpoch: "e", dataVersion: "v", demandRevision: UUID())
        let ascii = window(token: token, ordinal: 0, title: "abc")
        let unicode = window(token: token, ordinal: 1, title: "界界界")
        XCTAssertEqual(EPGGuideCost.programme(unicode) - EPGGuideCost.programme(ascii), 6)
    }

    func testXMLTVCoherenceGateRestartsOnlyOnceForOriginalDemand() {
        let demandRevision = UUID()
        let incarnation = UUID()
        let first = EPGResultToken(serviceIncarnation: incarnation,
            resourceIdentity: "resource", sourceEpoch: "epoch",
            dataVersion: "g1", demandRevision: demandRevision)
        let second = EPGResultToken(serviceIncarnation: incarnation,
            resourceIdentity: "resource", sourceEpoch: "epoch",
            dataVersion: "g2", demandRevision: demandRevision)
        var gate = EPGGuideCoherenceGate(demandRevision: demandRevision, capability: .xmltv)

        XCTAssertEqual(gate.admit(first), .accepted)
        XCTAssertEqual(gate.admit(first), .accepted)
        XCTAssertEqual(gate.admit(second), .restartDemand)
        XCTAssertEqual(gate.restartCount, 1)
        XCTAssertNil(gate.xmltvToken)
        XCTAssertEqual(gate.admit(second), .accepted)
        XCTAssertEqual(gate.snapshotChanged(), .failed(.snapshotChanged))
    }

    func testCoherenceGateRejectsAnotherDemandAndXtreamUsesPerRowTokens() {
        let demandRevision = UUID()
        let token = EPGResultToken(serviceIncarnation: UUID(), resourceIdentity: "resource",
            sourceEpoch: "epoch", dataVersion: "version", demandRevision: UUID())
        var xmltv = EPGGuideCoherenceGate(demandRevision: demandRevision, capability: .xmltv)
        XCTAssertEqual(xmltv.admit(token), .failed(.invalidRequest))

        let matching = EPGResultToken(serviceIncarnation: UUID(), resourceIdentity: "other",
            sourceEpoch: "different", dataVersion: "per-row", demandRevision: demandRevision)
        var xtream = EPGGuideCoherenceGate(demandRevision: demandRevision,
                                           capability: .xtreamShort)
        XCTAssertEqual(xtream.admit(matching), .accepted)
        XCTAssertNil(xtream.xmltvToken)
        XCTAssertEqual(xtream.snapshotChanged(), .failed(.snapshotChanged))
    }

    private func demand(count: Int,
                        slices supplied: [EPGGuideTimeSlice]? = nil) throws -> EPGGuideDemand {
        let slices = try supplied ?? [EPGGuideTimeSlice(start: anchor,
            end: anchor.addingTimeInterval(12 * 60 * 60))]
        return try EPGGuideDemand(source: EPGSourceKey(.imported(UUID())),
            revision: String(repeating: "a", count: 64), demandRevision: UUID(),
            capability: .xmltv, channels: (0..<count).map(live),
            visibleRange: 0..<min(count, 12), slices: slices)
    }

    private func live(_ index: Int) -> LiveChannel {
        LiveChannel(groupName: "Group", name: "Channel \(index)", tvgID: "c\(index)",
                    streams: [], explicitID: "channel-\(index)")
    }

    private func window(token: EPGResultToken, ordinal: Int,
                        title: String = "Programme") -> EPGWindowProgramme {
        EPGWindowProgramme(id: EPGProgrammeRecordIdentity(kind: .xmltv,
            resourceIdentity: token.resourceIdentity, sourceEpoch: token.sourceEpoch,
            dataVersion: token.dataVersion, ordinal: ordinal),
            programme: EPGProgramme(channelID: "c0", title: title,
                start: anchor, end: anchor.addingTimeInterval(1_800)))
    }
}
