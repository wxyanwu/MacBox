import Foundation
import OKVideoCore

/// Builds one bounded, coherent XMLTV guide snapshot from the production
/// repository. A snapshot is never returned with rows from two generations.
public enum EPGGuideXMLTVLoader {
    public static func load(
        repository: EPGProductionRepository,
        key: EPGRequestKey,
        demand: EPGGuideDemand,
        availability: EPGAvailability,
        retainedSnapshotCost: Int = 0
    ) async throws -> EPGGuideSnapshot {
        guard demand.capability == .xmltv,
              demand.source == key.source,
              demand.revision == key.revision,
              key.resource == "xmltv" else {
            throw EPGGuideFailure.invalidRequest
        }

        var gate = EPGGuideCoherenceGate(
            demandRevision: demand.demandRevision,
            capability: .xmltv
        )
        while true {
            do {
                let snapshot = try await loadAttempt(
                    repository: repository,
                    key: key,
                    demand: demand,
                    availability: availability,
                    retainedSnapshotCost: retainedSnapshotCost,
                    gate: &gate
                )
                let status = await repository.status(for: key)
                guard let summary = status.summary,
                      case .xmltv(let token) = snapshot.coherence,
                      summary.resourceIdentity == token.resourceIdentity,
                      summary.sourceEpoch == token.sourceEpoch,
                      summary.dataVersion == token.dataVersion else {
                    throw AttemptError.snapshotChanged
                }
                return snapshot
            } catch AttemptError.snapshotChanged {
                switch gate.snapshotChanged() {
                case .restartDemand:
                    continue
                case .failed(let failure):
                    throw failure
                case .accepted:
                    throw EPGGuideFailure.snapshotChanged
                }
            } catch AttemptError.restartAuthorized {
                continue
            } catch let failure as EPGGuideFailure {
                throw failure
            } catch is CancellationError {
                throw EPGGuideFailure.cancelled
            } catch {
                throw EPGGuideFailure.unavailable
            }
        }
    }

    private enum AttemptError: Error { case snapshotChanged, restartAuthorized }

    private struct CursorKey: Hashable, Sendable {
        let workID: EPGGuideWorkID
        let sliceIndex: Int
    }

    private struct RowAssembly: Sendable {
        var token: EPGResultToken?
        var match = EPGChannelMatch(kind: .unmatched, channelID: nil)
        var records: [EPGProgrammeRecordIdentity: EPGWindowProgramme] = [:]
    }

    private struct QueryOutcome: Sendable {
        let assignment: EPGGuideWorkAssignment
        let result: Result<EPGProductionWindowResult, EPGGuideFailure>
    }

    private static func loadAttempt(
        repository: EPGProductionRepository,
        key: EPGRequestKey,
        demand: EPGGuideDemand,
        availability: EPGAvailability,
        retainedSnapshotCost: Int,
        gate: inout EPGGuideCoherenceGate
    ) async throws -> EPGGuideSnapshot {
        var coordinator = try EPGGuideWorkCoordinator(
            demand: demand,
            retainedSnapshotCost: retainedSnapshotCost
        )
        var rows = Array(repeating: RowAssembly(), count: demand.channels.count)
        var cursors: [CursorKey: EPGProductionWindowCursor] = [:]

        while !coordinator.isFinished {
            try Task.checkCancellation()
            let assignments = coordinator.nextAssignments()
            guard !assignments.isEmpty else {
                throw EPGGuideFailure.queryBudgetExceeded
            }

            let outcomes = await withTaskGroup(of: QueryOutcome.self) { group in
                for assignment in assignments {
                    let cursor = cursors[CursorKey(
                        workID: assignment.id,
                        sliceIndex: assignment.sliceIndex
                    )]
                    group.addTask {
                        do {
                            let value = try await repository.queryXMLTVWindow(
                                assignment.channel,
                                for: key,
                                from: assignment.slice.start,
                                to: assignment.slice.end,
                                limit: EPGGuideLimits.pageSize,
                                cursor: cursor,
                                demandRevision: demand.demandRevision
                            )
                            return QueryOutcome(assignment: assignment, result: .success(value))
                        } catch {
                            return QueryOutcome(
                                assignment: assignment,
                                result: .failure(map(error))
                            )
                        }
                    }
                }
                var values: [QueryOutcome] = []
                for await value in group { values.append(value) }
                return values.sorted {
                    $0.assignment.id.channelIndex < $1.assignment.id.channelIndex
                }
            }

            for outcome in outcomes {
                let assignment = outcome.assignment
                let rowIndex = assignment.id.channelIndex
                switch outcome.result {
                case .failure(.snapshotChanged):
                    throw AttemptError.snapshotChanged
                case .failure(let failure):
                    try coordinator.fail(assignment.id, failure)
                case .success(let value):
                    switch gate.admit(value.page.token) {
                    case .accepted:
                        break
                    case .restartDemand:
                        throw AttemptError.restartAuthorized
                    case .failed(let failure):
                        throw failure
                    }
                    var assembly = rows[rowIndex]
                    if let existing = assembly.token, existing != value.page.token {
                        throw AttemptError.snapshotChanged
                    }
                    assembly.token = value.page.token
                    assembly.match = value.page.match

                    switch value.page.match.kind {
                    case .ambiguous:
                        rows[rowIndex] = assembly
                        try coordinator.completePage(
                            assignment.id,
                            acceptedProgrammes: 0,
                            acceptedBytes: 0,
                            hasMore: false,
                            terminalState: .ambiguous
                        )
                    case .unmatched:
                        rows[rowIndex] = assembly
                        try coordinator.completePage(
                            assignment.id,
                            acceptedProgrammes: 0,
                            acceptedBytes: 0,
                            hasMore: false,
                            terminalState: .unmatched
                        )
                    case .exact, .normalizedUnique:
                        var acceptedCount = 0
                        var acceptedBytes = 0
                        for record in value.page.records where assembly.records[record.id] == nil {
                            assembly.records[record.id] = record
                            acceptedCount += 1
                            acceptedBytes += EPGGuideCost.programme(record)
                        }
                        rows[rowIndex] = assembly
                        let cursorKey = CursorKey(
                            workID: assignment.id,
                            sliceIndex: assignment.sliceIndex
                        )
                        if let cursor = value.nextCursor { cursors[cursorKey] = cursor }
                        else { cursors[cursorKey] = nil }
                        try coordinator.completePage(
                            assignment.id,
                            acceptedProgrammes: acceptedCount,
                            acceptedBytes: acceptedBytes,
                            hasMore: value.nextCursor != nil
                        )
                    }
                }
            }
        }

        guard let coherenceToken = gate.xmltvToken else {
            let failures = coordinator.terminalStates.compactMap { state -> EPGGuideFailure? in
                if case .failed(let failure) = state { return failure }
                return nil
            }
            throw failures.first ?? EPGGuideFailure.unavailable
        }
        let guideRows = zip(demand.channels.indices, coordinator.terminalStates).map { index, state in
            let assembly = rows[index]
            let ordered = assembly.records.values.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.ordinal < $1.id.ordinal
            }
            return EPGGuideRow(
                channel: EPGGuideChannel(demand.channels[index]),
                token: assembly.token,
                match: assembly.match,
                availability: availability,
                programmes: ordered,
                state: state
            )
        }
        return try EPGGuideSnapshot(
            source: demand.source,
            revision: demand.revision,
            demandRevision: demand.demandRevision,
            slices: demand.slices,
            coherence: .xmltv(coherenceToken),
            rows: guideRows
        )
    }

    private static func map(_ error: Error) -> EPGGuideFailure {
        if error is CancellationError { return .cancelled }
        guard let error = error as? EPGProductionServiceError else { return .unavailable }
        switch error {
        case .cancelled: return .cancelled
        case .busy: return .busy
        case .invalidRequest: return .invalidRequest
        case .snapshotChanged: return .snapshotChanged
        case .queryBudgetExceeded, .resultTooLarge: return .queryBudgetExceeded
        case .paused, .closed, .noActiveData, .unavailable: return .unavailable
        }
    }
}
