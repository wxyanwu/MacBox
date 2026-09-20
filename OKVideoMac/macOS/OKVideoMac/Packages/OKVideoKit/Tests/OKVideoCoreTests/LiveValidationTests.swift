import XCTest
@testable import OKVideoCore

private actor ValidationProbeFixture: LiveStreamProbing {
    var calls: [String] = []
    var active = 0
    var peak = 0
    var slowFinished = false
    let results: [String: LiveStreamProbeResult]
    let delays: [String: UInt64]
    init(results: [String: LiveStreamProbeResult] = [:], delays: [String: UInt64] = [:]) {
        self.results = results; self.delays = delays
    }
    func probe(_ stream: LiveStream) async -> LiveStreamProbeResult {
        let key = stream.name
        calls.append(key); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        do { try await Task.sleep(nanoseconds: delays[key] ?? 1_000_000) }
        catch { return .inconclusive }
        if key == "slow" { slowFinished = true }
        return results[key] ?? .reachable
    }
}

final class LiveValidationTests: XCTestCase {
    private func channel(_ name: String, routes: [String]? = nil) -> LiveChannel {
        .init(groupName: "G", name: name, streams: (routes ?? [name]).map {
            .init(name: $0, url: URL(string: "https://fixture.invalid/\($0)")!)
        })
    }
    private func run(_ service: LiveValidationService, _ channels: [LiveChannel]) async -> LiveValidationSummary {
        await service.run(channels: channels, permit: .init(sourceID: UUID())) { _, _ in }
    }
    func testFastCompletionsRefillPoolWithoutWaitingForSlowBatchMember() async {
        let fixture = ValidationProbeFixture(delays: ["slow": 800_000_000])
        let service = LiveValidationService(prober: fixture)
        let progressed = expectation(description: "more than one batch completed before slow member")
        let result = await service.run(channels: [channel("slow")] + (0..<10).map { channel("f\($0)") },
            permit: .init(sourceID: UUID())) { done, _ in
                if done == 8 {
                    let slowDone = await fixture.slowFinished
                    XCTAssertFalse(slowDone)
                    progressed.fulfill()
                }
            }
        await fulfillment(of: [progressed], timeout: 1)
        XCTAssertEqual(result.completed, 11); XCTAssertEqual(result.end, .complete)
    }
    func testGlobalSlotsStayBoundedAcrossOverlappingRunsAndCancellation() async throws {
        let fixture = ValidationProbeFixture(delays: ["slow": 80_000_000])
        let service = LiveValidationService(prober: fixture, concurrency: 4)
        let channels = (0..<12).map { channel("c\($0)", routes: ["slow"]) }
        let a = Task { await self.run(service, channels) }
        let b = Task { await self.run(service, channels) }
        try await Task.sleep(nanoseconds: 30_000_000)
        a.cancel()
        let old = await a.value, new = await b.value
        let peak = await fixture.peak, active = await fixture.active
        XCTAssertLessThanOrEqual(peak, 4); XCTAssertEqual(active, 0)
        XCTAssertEqual(old.end, .cancelled); XCTAssertEqual(new.end, .complete)
        XCTAssertEqual(new.completed, 12); XCTAssertTrue(old.unavailableIDs.isEmpty)
    }
    func testReachableFirstRouteShortCircuitsAlternates() async {
        let fixture = ValidationProbeFixture()
        let result = await run(.init(prober: fixture), [channel("c", routes: ["good", "unused"])])
        let calls = await fixture.calls
        XCTAssertEqual(calls, ["good"]); XCTAssertTrue(result.unavailableIDs.isEmpty)
    }
    func testInconclusiveStopsAutomaticHideWithoutScanningAlternates() async {
        let fixture = ValidationProbeFixture(results: ["unknown": .inconclusive])
        let result = await run(.init(prober: fixture), [channel("c", routes: ["unknown", "unused"])])
        let calls = await fixture.calls
        XCTAssertEqual(calls, ["unknown"]); XCTAssertTrue(result.unavailableIDs.isEmpty)
    }
    func testEveryRouteMustFailTwoConfirmations() async {
        let fixture = ValidationProbeFixture(results: ["a": .definitivelyUnavailable, "b": .definitivelyUnavailable])
        let c = channel("c", routes: ["a", "b"])
        let result = await run(.init(prober: fixture, confirmationDelay: 0), [c])
        let calls = await fixture.calls
        XCTAssertEqual(calls, ["a", "a", "b", "b"]); XCTAssertEqual(result.unavailableIDs, [c.id])
    }
    func testReachableAlternatePreventsHide() async {
        let fixture = ValidationProbeFixture(results: ["bad": .definitivelyUnavailable])
        let result = await run(.init(prober: fixture, confirmationDelay: 0),
            [channel("c", routes: ["bad", "good", "unused"])])
        let calls = await fixture.calls
        XCTAssertEqual(calls, ["bad", "bad", "good"]); XCTAssertTrue(result.unavailableIDs.isEmpty)
    }
    func testEmptyChannelIsNeverAutomaticallyHidden() async {
        let result = await run(.init(prober: ValidationProbeFixture()), [channel("empty", routes: [])])
        XCTAssertTrue(result.unavailableIDs.isEmpty); XCTAssertEqual(result.end, .complete)
    }
    func testPerChannelBudgetIsInconclusiveAndAllowsRoundToComplete() async {
        let fixture = ValidationProbeFixture(results: ["slow": .definitivelyUnavailable], delays: ["slow": 5_000_000_000])
        let result = await run(.init(prober: fixture, channelBudget: 0.03), [channel("slow"), channel("good")])
        XCTAssertEqual(result.end, .complete); XCTAssertEqual(result.completed, 2)
        XCTAssertTrue(result.unavailableIDs.isEmpty)
        let active = await fixture.active; XCTAssertEqual(active, 0)
    }
    func testRoundDeadlineDiscardsAlreadyConfirmedUnavailableSubset() async {
        let fixture = ValidationProbeFixture(results: ["bad": .definitivelyUnavailable], delays: ["slow": 5_000_000_000])
        let result = await run(.init(prober: fixture, roundBudget: 0.08, confirmationDelay: 0),
            [channel("bad"), channel("slow")])
        XCTAssertEqual(result.end, .budgetExceeded); XCTAssertEqual(result.completed, 1)
        XCTAssertTrue(result.unavailableIDs.isEmpty)
    }
    func testCancellationDiscardsConfirmedSubsetAndDrains() async throws {
        let fixture = ValidationProbeFixture(results: ["bad": .definitivelyUnavailable], delays: ["slow": 5_000_000_000])
        let service = LiveValidationService(prober: fixture, confirmationDelay: 0)
        let reached = expectation(description: "bad completed")
        let permit = LiveValidationPermit(sourceID: UUID())
        let task = Task {
            await service.run(channels: [channel("bad"), channel("slow")], permit: permit) { _, _ in reached.fulfill() }
        }
        await fulfillment(of: [reached], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.end, .cancelled); XCTAssertTrue(result.unavailableIDs.isEmpty)
        XCTAssertTrue(permit.isCancelled)
        let active = await fixture.active; XCTAssertEqual(active, 0)
    }
    func testCancelledPermitDoesNotStartAnyProbe() async {
        let fixture = ValidationProbeFixture(), permit = LiveValidationPermit(sourceID: UUID())
        permit.cancel()
        let result = await LiveValidationService(prober: fixture).run(channels: [channel("a")], permit: permit) { _, _ in XCTFail() }
        let calls = await fixture.calls
        XCTAssertEqual(result.end, .cancelled); XCTAssertTrue(calls.isEmpty)
    }
    func testEmptyRoundFinishesWithoutNetwork() async {
        let result = await run(.init(prober: ValidationProbeFixture()), [])
        XCTAssertEqual(result.end, .complete); XCTAssertEqual(result.total, 0)
    }
    func testCancellationWinsBeforeCommit() {
        let permit = LiveValidationPermit(sourceID: UUID())
        permit.cancel()
        XCTAssertThrowsError(try permit.commit { XCTFail("must not execute") })
        XCTAssertFalse(permit.didCommit)
    }
    func testCommitWinsThenCancellationCannotLieAboutOutcome() throws {
        let permit = LiveValidationPermit(sourceID: UUID())
        try permit.commit {}
        XCTAssertTrue(permit.didCommit); XCTAssertFalse(permit.cancel()); XCTAssertFalse(permit.isCancelled)
        XCTAssertThrowsError(try permit.commit {})
    }
    func testThrowingCommitDoesNotMarkCommitted() {
        let permit = LiveValidationPermit(sourceID: UUID())
        XCTAssertThrowsError(try permit.commit { throw CancellationError() })
        XCTAssertFalse(permit.didCommit); XCTAssertTrue(permit.cancel())
    }
}
