import Foundation
import OKVideoCore
import OKVideoPersistence

/// Explicit developer invocation; no normal startup calls and no Library input.
public enum ImportedAcceptanceRehearsal {
    public static func copy(snapshot: URL, root: URL) throws {
        let workspace = try ImportedAcceptanceWorkspace(root: root)
        let source = snapshot.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard source.deletingLastPathComponent().deletingLastPathComponent() == temporary,
              source.deletingLastPathComponent().lastPathComponent.hasPrefix("OKVideoMac-8B2-DryRun-"),
              source.lastPathComponent == "staged.sqlite3" else { throw SnapshotError.unsafeFile }
        let a = try FileManager.default.attributesOfItem(atPath: source.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              (a[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SnapshotError.unsafeFile }
        _ = try AppDirectories(applicationSupport: workspace.support, caches: workspace.caches)
        try ImportedMigrationRehearsal.backup(source: source, destination: workspace.databaseURL)
    }
    public static func cycle(root: URL, label: String) async throws {
        guard !label.isEmpty, label.utf8.count < 40,
              label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw SnapshotError.unsafeFile }
        let workspace = try ImportedAcceptanceWorkspace(root: root)
        let db = try SQLiteStore(importedAcceptance: workspace)
        let sources = try await db.liveSources()
        struct Summary: Codable {
            let source: UUID; let channels: Int; let identitiesBefore: Int; let identitiesAfter: Int
            let stableHidden: Int; let blockedHidden: Int; let identities: [ImportedLiveChannelIdentity]
        }
        var result: [Summary] = []
        for source in sources.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let channels = try LiveSourceParser().parse(source.rawData, baseURL: source.baseURL).groups.flatMap(\.channels)
            let before = try await db.importedChannelIdentities(for: .imported(source.id))
            let g = ImportedCatalogGeneration(sourceID: source.id)
            let mapping = try await db.importedCatalogMapping(sourceID: source.id, generation: g)
            let after = try await db.importedChannelIdentities(for: .imported(source.id))
            result.append(Summary(source: source.id, channels: channels.count, identitiesBefore: before.count,
                identitiesAfter: after.count, stableHidden: channels.filter {
                    if case .stable = mapping.authority(channel: $0, kind: .hidden) { return true }; return false
                }.count, blockedHidden: channels.filter { mapping.authority(channel: $0, kind: .hidden) == .blocked }.count,
                identities: after.map(\.identity)))
            g.invalidate()
        }
        guard try await db.liveSources() == sources else { throw SnapshotError.invalidDatabase }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try QuiescentDatabaseSnapshot.writePrivate(encoder.encode(result), to: workspace.root.appendingPathComponent("\(label).json"))
        print("Actor rehearsal: sources=\(result.count), channels=\(result.reduce(0) { $0 + $1.channels }), identities=\(result.reduce(0) { $0 + $1.identitiesAfter }). Real DB access: NO.")
    }
}
