import Foundation
import OKVideoCore

extension SQLiteStore {
    public static let epgPreferencesKey = "live.epg.preferences.v1"

    public func epgPreferences() throws -> EPGPreferences {
        guard let value = try setting(forKey: Self.epgPreferencesKey) else { return EPGPreferences() }
        return try JSONDecoder().decode(EPGPreferences.self, from: JSONEncoder().encode(value))
    }

    public func saveEPGPreferences(_ preferences: EPGPreferences) throws {
        let validated = try preferences.validated()
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(validated))
        try setSetting(value, forKey: Self.epgPreferencesKey)
    }
}
