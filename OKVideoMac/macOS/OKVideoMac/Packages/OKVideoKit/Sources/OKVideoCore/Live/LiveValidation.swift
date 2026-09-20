import Foundation

public enum LiveStreamProbeResult: Equatable, Sendable {
    case reachable, definitivelyUnavailable, inconclusive
}

public enum LiveSourceValidationPolicy {
    public static func result(forHTTPStatus statusCode: Int) -> LiveStreamProbeResult {
        switch statusCode {
        case 200...399: return .reachable
        case 400, 401, 403, 404, 410, 451: return .definitivelyUnavailable
        default: return .inconclusive
        }
    }
    public static func shouldRemoveChannel(streamResults: [LiveStreamProbeResult]) -> Bool {
        !streamResults.isEmpty && streamResults.allSatisfy { $0 == .definitivelyUnavailable }
    }
}

/// Additional run-local veto, never identity/source authority. Cancellation and
/// COMMIT have one linearization point; committed data is not undone by cancel.
public final class LiveValidationPermit: @unchecked Sendable {
    public let id = UUID()
    public let sourceID: UUID
    private let lock = NSRecursiveLock()
    private enum State { case active, cancelled, committed }
    private var state = State.active
    public init(sourceID: UUID) { self.sourceID = sourceID }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return state == .cancelled }
    public var didCommit: Bool { lock.lock(); defer { lock.unlock() }; return state == .committed }
    @discardableResult public func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state != .committed else { return false }
        state = .cancelled; return true
    }
    public func commit<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard state == .active else { throw CancellationError() }
        let value = try body()
        state = .committed
        return value
    }
}

public protocol LiveStreamProbing: Sendable {
    /// Must finish promptly on task cancellation. This is required for draining
    /// structured timeout races; a timeout wrapper alone cannot stop a transport.
    func probe(_ stream: LiveStream) async -> LiveStreamProbeResult
}

/// One pool shared by every source/run, including cancelled runs still draining.
/// Capacity transfers only after the previous probe operation has returned.
private actor LiveProbeSlots {
    private var available: Int
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(_ capacity: Int) { available = capacity }
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if available > 0 { available -= 1; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: i).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().1.resume() }
    }
}

public struct LiveValidationSummary: Sendable, Equatable {
    public enum End: Sendable, Equatable { case complete, cancelled, budgetExceeded }
    public let end: End
    public let completed: Int
    public let total: Int
    public let unavailableIDs: Set<String>
}

/// Fixed worker window + shared transport slots, not batches or a scheduler.
public final class LiveValidationService: @unchecked Sendable {
    private let prober: any LiveStreamProbing
    private let slots: LiveProbeSlots
    private let concurrency: Int
    private let channelBudget: TimeInterval
    private let roundBudget: TimeInterval
    private let confirmationDelay: TimeInterval
    public var maximumRunDuration: TimeInterval { roundBudget }
    public init(prober: any LiveStreamProbing = BoundedLiveStreamProber(), concurrency: Int = 4,
                channelBudget: TimeInterval = 15, roundBudget: TimeInterval = 120,
                confirmationDelay: TimeInterval = 0.4) {
        self.prober = prober; self.concurrency = max(1, min(4, concurrency))
        self.slots = LiveProbeSlots(max(1, min(4, concurrency)))
        self.channelBudget = max(0.01, min(60, channelBudget))
        self.roundBudget = max(0.01, min(600, roundBudget))
        self.confirmationDelay = max(0, min(1, confirmationDelay))
    }
    private static func sleep(_ seconds: TimeInterval) async throws {
        // Task.sleep uses elapsed monotonic time, not wall-clock Date changes.
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private func probe(_ stream: LiveStream) async -> LiveStreamProbeResult {
        do { try await slots.acquire() } catch { return .inconclusive }
        let result: LiveStreamProbeResult
        if Task.isCancelled { result = .inconclusive }
        else { result = await prober.probe(stream) }
        await slots.release()
        return Task.isCancelled ? .inconclusive : result
    }
    private func channel(_ channel: LiveChannel) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await Self.sleep(self.channelBudget) } catch {}
                return false
            }
            group.addTask {
                guard !channel.streams.isEmpty else { return false }
                for stream in channel.streams {
                    guard !Task.isCancelled else { return false }
                    let first = await self.probe(stream)
                    // Either outcome prevents all-lines-definitively-unavailable.
                    guard first == .definitivelyUnavailable else { return false }
                    do { try await Self.sleep(self.confirmationDelay) } catch { return false }
                    guard await self.probe(stream) == .definitivelyUnavailable else { return false }
                }
                return !Task.isCancelled
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return Task.isCancelled ? false : result
        }
    }
    public func run(channels: [LiveChannel], permit: LiveValidationPermit,
                    progress: @escaping @Sendable (Int, Int) async -> Void) async -> LiveValidationSummary {
        guard !Task.isCancelled, !permit.isCancelled else {
            permit.cancel()
            return .init(end: .cancelled, completed: 0, total: channels.count, unavailableIDs: [])
        }
        enum Event { case channel(Int, Bool), deadline }
        return await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: Event.self) { group in
                group.addTask {
                    do { try await Self.sleep(self.roundBudget) } catch {}
                    return .deadline
                }
                var next = 0, completed = 0, unavailable = Set<String>()
                func schedule() {
                    guard next < channels.count else { return }
                    let index = next; next += 1
                    group.addTask { .channel(index, await self.channel(channels[index])) }
                }
                for _ in 0..<min(concurrency, channels.count) { schedule() }
                var end = LiveValidationSummary.End.complete
                while completed < channels.count, let event = await group.next() {
                    if Task.isCancelled || permit.isCancelled { end = .cancelled; break }
                    switch event {
                    case .deadline: end = .budgetExceeded
                    case .channel(let index, let failed):
                        completed += 1
                        if failed { unavailable.insert(channels[index].id) }
                        await progress(completed, channels.count)
                        schedule()
                    }
                    if end != .complete { break }
                }
                if Task.isCancelled || permit.isCancelled { end = .cancelled }
                if end != .complete { permit.cancel(); unavailable.removeAll() }
                group.cancelAll()
                return LiveValidationSummary(end: end, completed: completed, total: channels.count, unavailableIDs: unavailable)
            }
        }, onCancel: { permit.cancel() })
    }
}
