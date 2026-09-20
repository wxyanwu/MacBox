import Foundation

/// Small actor owns cache and refresh coordination. Fetch closures are runtime
/// only: neither endpoints nor credentials are encoded into the cache.
public actor EPGRepository {
    private struct Entry: Codable {
        var version = 1
        let key: EPGRequestKey
        let fetchedAt: Date
        var expiresAt: Date
        let guide: XMLTVGuide
        var availability: EPGAvailability
    }
    private struct Flight {
        let id: UUID
        let task: Task<EPGSnapshot, Error>
    }
    private let directory: URL
    private let now: @Sendable () -> Date
    private let maximumEntries: Int
    private var entries: [EPGRequestKey: Entry] = [:]
    private var access: [EPGRequestKey: Date] = [:]
    private var flights: [EPGRequestKey: Flight] = [:]

    public init(cacheDirectory: URL, maximumEntries: Int = 32,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        directory = cacheDirectory
        self.now = now
        self.maximumEntries = max(1, maximumEntries)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func cached(_ key: EPGRequestKey) -> EPGSnapshot? {
        guard let entry = read(key) else { return nil }
        return snapshot(entry, stale: entry.expiresAt <= now())
    }

    /// One-way, read-only import of the previous URL-keyed XMLTV cache. The
    /// endpoint digest must match the new revision; legacy files stay intact.
    public func migrateLegacyXMLTV(_ key: EPGRequestKey, from legacyDirectory: URL) {
        guard key.source.kind == .imported, key.resource == "xmltv", read(key) == nil,
              key.revision.count == 64,
              key.revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return }
        struct Legacy: Decodable { let fetchedAt: Date; let guide: XMLTVGuide }
        let file = legacyDirectory.appendingPathComponent(key.revision + ".json")
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
              size.intValue <= 80 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              legacy.guide.programmes.count <= 200_000 else { return }
        let entry = Entry(key: key, fetchedAt: legacy.fetchedAt,
            expiresAt: legacy.fetchedAt.addingTimeInterval(6 * 3600), guide: legacy.guide,
            availability: legacy.guide.programmes.isEmpty ? .empty : .fresh)
        remember(entry)
        try? persist(entry)
    }

    public func load(_ key: EPGRequestKey, ttl: TimeInterval, force: Bool = false,
                     fetch: @escaping @Sendable () async throws -> EPGPayload) async throws -> EPGSnapshot {
        try Task.checkCancellation()
        if let flight = flights[key] { return try await flight.task.value }
        let old = read(key)
        if !force, let old, old.expiresAt > now() { return snapshot(old) }
        let id = UUID()
        let task = Task<EPGSnapshot, Error>(priority: .utility) {
            do {
                let payload = try await fetch()
                try Task.checkCancellation()
                guard self.flights[key]?.id == id else { throw CancellationError() }
                guard payload.guide.programmes.count <= 200_000 else { throw EPGFetchError.malformed }
                let date = self.now()
                let availability: EPGAvailability = payload.unsupported ? .unsupported
                    : (payload.guide.programmes.isEmpty ? .empty : .fresh)
                let duration = payload.unsupported ? 3600 : (payload.guide.programmes.isEmpty ? 900 : ttl)
                var expires = date.addingTimeInterval(max(60, duration))
                if let end = payload.guide.programmes.map(\.end).max() {
                    expires = min(expires, max(date.addingTimeInterval(60), end.addingTimeInterval(-60)))
                }
                let entry = Entry(key: key, fetchedAt: date, expiresAt: expires,
                                  guide: payload.guide, availability: availability)
                self.remember(entry)
                // Disk failure must not discard successfully fetched in-memory data.
                try? self.persist(entry)
                return self.snapshot(entry)
            } catch {
                guard !Task.isCancelled, self.flights[key]?.id == id,
                      !(error is CancellationError),
                      (error as? HTTPClientError) != .cancelled else { throw CancellationError() }
                if var old {
                    old.availability = .stale
                    old.expiresAt = self.now().addingTimeInterval(60)
                    self.remember(old)
                    return self.snapshot(old)
                }
                let empty = Entry(key: key, fetchedAt: self.now(),
                                  expiresAt: self.now().addingTimeInterval(60),
                                  guide: XMLTVGuide(channels: [], programmes: []), availability: .failed)
                self.remember(empty)
                return self.snapshot(empty)
            }
        }
        flights[key] = Flight(id: id, task: task)
        defer { if flights[key]?.id == id { flights[key] = nil } }
        return try await task.value
    }

    public func cancelRequests() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    public func invalidate(source: EPGSourceKey, removeCache: Bool = true) {
        for key in Array(flights.keys) where key.source == source {
            flights.removeValue(forKey: key)?.task.cancel()
        }
        guard removeCache else { return }
        entries = entries.filter { $0.key.source != source }
        access = access.filter { $0.key.source != source }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory,
                      includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(prefix(source)) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func snapshot(_ entry: Entry, stale: Bool = false) -> EPGSnapshot {
        EPGSnapshot(key: entry.key,
                    availability: stale && entry.availability == .fresh ? .stale : entry.availability,
                    fetchedAt: entry.availability == .failed ? nil : entry.fetchedAt,
                    retryAfter: entry.expiresAt, guide: entry.guide)
    }

    private func remember(_ entry: Entry) {
        entries[entry.key] = entry
        access[entry.key] = now()
        while entries.count > maximumEntries || entries.values.reduce(0, { $0 + $1.guide.programmes.count }) > 400_000,
              let oldest = access.min(by: { $0.value < $1.value })?.key {
            entries[oldest] = nil
            access[oldest] = nil
        }
    }

    private func read(_ key: EPGRequestKey) -> Entry? {
        if let entry = entries[key] { access[key] = now(); return entry }
        let file = path(key)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 80 * 1024 * 1024 else {
                throw EPGFetchError.malformed
            }
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard entry.version == 1, entry.key == key,
                  entry.guide.programmes.count <= 200_000 else { throw EPGFetchError.malformed }
            remember(entry)
            return entry
        } catch {
            // A corrupt/obsolete cache must not prevent a network recovery.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    private func persist(_ entry: Entry) throws {
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 80 * 1024 * 1024 else { return }
        let file = path(entry.key)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var bytes = 0
        for (index, url) in files.enumerated() {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if index >= 128 || bytes > 128 * 1024 * 1024 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func prefix(_ source: EPGSourceKey) -> String {
        "\(source.kind.rawValue)-\(source.id.uuidString.lowercased())-"
    }

    private func path(_ key: EPGRequestKey) -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = EPGRequestKey.revision(for: (try? encoder.encode(key)) ?? Data())
        return directory.appendingPathComponent(prefix(key.source) + digest + ".json")
    }
}
