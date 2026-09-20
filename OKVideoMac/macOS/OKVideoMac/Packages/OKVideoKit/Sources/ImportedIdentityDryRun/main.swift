import Foundation
import OKVideoMigrationDiagnostics

@main
enum ImportedIdentityDryRunCommand {
    static func main() async {
        // No default user-library path and no startup integration. Explicit
        // invocation only, AFTER tests and checking no external DB clients exist.
        let arguments = CommandLine.arguments
        do {
            if arguments.count == 4 && arguments[1] == "--shadow-replay" {
                let report = try ImportedShadowDiff.replay(snapshot: URL(fileURLWithPath: arguments[2]), output: URL(fileURLWithPath: arguments[3]))
                print("Frozen shadow replay: sources=\(report.sources.count); no live database connection.")
                return
            }
            if arguments.count == 4 && arguments[1] == "--shadow-diff" {
                let report = try ImportedShadowDiff.run(temporaryInput: URL(fileURLWithPath: arguments[2]), output: URL(fileURLWithPath: arguments[3]))
                print("Shadow report: sources=\(report.sources.count), channels=\(report.sources.reduce(0) { $0 + $1.oldChannels }); UUID allocation=0; Registry writes=0.")
                return
            }
            if arguments.count == 4 && arguments[1] == "--app-acceptance-copy" {
                try ImportedAcceptanceRehearsal.copy(snapshot: URL(fileURLWithPath: arguments[2]), root: URL(fileURLWithPath: arguments[3]))
                print("Isolated App database copied from previous temporary snapshot only.")
                return
            }
            if arguments.count == 4 && arguments[1] == "--app-acceptance-cycle" {
                try await ImportedAcceptanceRehearsal.cycle(root: URL(fileURLWithPath: arguments[2]), label: arguments[3])
                return
            }
            if arguments.count == 4 && arguments[1] == "--migration-copy" {
                try ImportedMigrationRehearsal.copy(snapshot: URL(fileURLWithPath: arguments[2]), into: URL(fileURLWithPath: arguments[3]))
                print("Consistent temporary baseline/work copies created. No user database access.")
                return
            }
            if arguments.count == 4 && ["--migration-cycle", "--migration-unhide"].contains(arguments[1]) {
                try ImportedMigrationRehearsal.cycle(in: URL(fileURLWithPath: arguments[2]), label: arguments[3], unhide: arguments[1] == "--migration-unhide")
                return
            }
            if arguments.count == 4 && arguments[1] == "--admission-plan" {
                let input = try ImportedAdmissionSnapshot.read(temporaryDatabase: URL(fileURLWithPath: arguments[2]))
                let session = ImportedAdmissionSession()
                let plan = try session.prepare(input)
                let output = URL(fileURLWithPath: arguments[3]).resolvingSymlinksInPath()
                let root = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
                guard output.deletingLastPathComponent() == root,
                      output.lastPathComponent.hasPrefix("OKVideoMac-8B2b-") else { throw SnapshotError.unsafeFile }
                try QuiescentDatabaseSnapshot.writePrivate(plan.json(), to: output.appendingPathComponent("AdmissionPlan.json"))
                try QuiescentDatabaseSnapshot.writePrivate(Data(plan.markdown().utf8), to: output.appendingPathComponent("AdmissionPlan.md"))
                print("Frozen snapshot admission only: \(plan.counts). No real database connection or migration.")
                return
            }
            if arguments.count == 4 && arguments[1] == "--capture-parser-golden" {
                try ParserOutputEquivalence.write(ParserOutputEquivalence.capture(temporaryDatabase: URL(fileURLWithPath: arguments[2])),
                    to: URL(fileURLWithPath: arguments[3]))
                print("Parser golden captured (temporary database only).")
                return
            }
            if arguments.count == 3 && arguments[1] == "--capture-fixture-golden" {
                try ParserOutputEquivalence.write(ParserOutputEquivalence.fixtureDigests(), to: URL(fileURLWithPath: arguments[2]))
                print("Fixture golden captured.")
                return
            }
        } catch {
            let code = (error as? SnapshotError).map { String(describing: $0) } ?? String(reflecting: type(of: error))
            print("Golden capture failed (\(code)); payload omitted."); exit(1)
        }
        guard (arguments.count == 4 || arguments.count == 6 && arguments[4] == "--parser-golden"), arguments[1] == "--quiescent-database" else {
            print("Usage: ImportedIdentityDryRun --quiescent-database DATABASE EXISTING_APP_LOCK [--parser-golden GOLDEN_JSON]")
            exit(2)
        }
        do {
            let real = URL(fileURLWithPath: arguments[2])
            let snapshot = try QuiescentDatabaseSnapshot.create(database: real,
                existingAppLock: URL(fileURLWithPath: arguments[3]))
            if arguments.count == 6 {
                let expected = try JSONDecoder().decode([ParserOutputEquivalence.SourceGolden].self,
                    from: Data(contentsOf: URL(fileURLWithPath: arguments[5])))
                let actual = try ParserOutputEquivalence.capture(temporaryDatabase: snapshot.database)
                guard expected == actual else { throw SnapshotError.invalidDatabase }
                try ParserOutputEquivalence.write(actual, to: snapshot.directory.appendingPathComponent("ParserEquivalenceVerified.json"))
            }
            let plan = try await ImportedMigrationDryRun.run(snapshot: snapshot)
            try ImportedMigrationDryRun.writeReports(plan: plan, snapshot: snapshot, realDatabase: real)
            print("Reports: \(snapshot.directory.path)")
            print("Sources: \(plan.sources.count); channels: \(plan.channels.count); references: \(plan.references.count)")
            for item in plan.channelCounts.sorted(by: { $0.key < $1.key }) { print("\(item.key): \(item.value)") }
        } catch {
            // Do not emit localizedDescription, paths, raw settings, parser data,
            // SQLite row values or credential-bearing URLs on failure.
            print("Dry-run stopped safely. No user database SQLite connection was opened. Review snapshot preconditions or failing tests.")
            exit(1)
        }
    }
}
