import AndroidRuntimeKit
import Foundation
import AppKit

/// Cancels and joins complete Bridge operations, not just their current HTTP
/// request. Deferred polling cannot survive maintenance and start the guest.
actor AndroidBridgeOperationAdmission {
    private struct Operation {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }
    private var closed = false
    private var operations: [UUID: Operation] = [:]

    func perform<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw RuntimeMaintenanceError.busy }
        let id = UUID()
        let task = Task { try await body() }
        operations[id] = Operation(cancel: { task.cancel() }, wait: { _ = await task.result })
        defer { operations[id] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func closeAndWait() async throws {
        guard !closed else { throw RuntimeMaintenanceError.busy }
        closed = true
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.wait() }
    }

    func reopen() { closed = false }
}
