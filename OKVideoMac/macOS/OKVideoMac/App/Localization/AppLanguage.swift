import Foundation

enum AppLanguageMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.string(.languageFollowSystem)
        case .simplifiedChinese:
            return L10n.string(.languageSimplifiedChinese)
        case .english:
            return L10n.string(.languageEnglish)
        }
    }
}

enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var locale: Locale { Locale(identifier: rawValue) }
    var resourceName: String { rawValue }
}

enum AppLanguageResolver {
    static func resolve(
        mode: AppLanguageMode,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch mode {
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        case .system:
            return resolveSystemLanguage(preferredLanguages: preferredLanguages)
        }
    }

    static func resolveSystemLanguage(
        preferredLanguages: [String]
    ) -> AppLanguage {
        guard let preferred = preferredLanguages.first else {
            return .english
        }
        let normalized = preferred.replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized == "zh-hans"
            || normalized.hasPrefix("zh-hans-")
            || normalized == "zh-cn"
            || normalized.hasPrefix("zh-cn-")
            || normalized == "zh-sg"
            || normalized.hasPrefix("zh-sg-") {
            return .simplifiedChinese
        }
        return .english
    }
}

struct AppLanguagePreferenceStore {
    static let key = "OKVideoMac.UILanguageMode.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppLanguageMode {
        guard let rawValue = defaults.string(forKey: Self.key),
              let mode = AppLanguageMode(rawValue: rawValue) else {
            return .system
        }
        return mode
    }

    func save(_ mode: AppLanguageMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}
