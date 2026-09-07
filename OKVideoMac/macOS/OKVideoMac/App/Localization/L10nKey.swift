import Foundation

struct L10nKey: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension L10nKey {
    static let commonOK = Self(rawValue: "common.ok")
    static let commonCancel = Self(rawValue: "common.cancel")
    static let commonRestart = Self(rawValue: "common.restart")

    static let languageFollowSystem = Self(rawValue: "language.follow-system")
    static let languageSimplifiedChinese = Self(rawValue: "language.zh-hans")
    static let languageEnglish = Self(rawValue: "language.en")
    static let languageTitle = Self(rawValue: "settings.language.title")
    static let languageSubtitle = Self(rawValue: "settings.language.subtitle")
    static let languageRestartTitle = Self(rawValue: "settings.language.restart.title")
    static let languageRestartMessage = Self(rawValue: "settings.language.restart.message")
    static let languageRestartLater = Self(rawValue: "settings.language.restart.later")
    static let languageRestartFailureTitle = Self(rawValue: "settings.language.restart.failure.title")
    static let languageRestartFailureMessage = Self(rawValue: "settings.language.restart.failure.message")

    static let sectionBrowse = Self(rawValue: "sidebar.browse")
    static let sectionLiveTV = Self(rawValue: "sidebar.live-tv")
    static let sectionFavorites = Self(rawValue: "sidebar.favorites")
    static let sectionHistory = Self(rawValue: "sidebar.history")
    static let sectionSettings = Self(rawValue: "sidebar.settings")

    static let themeSystem = Self(rawValue: "theme.system")
    static let themeLight = Self(rawValue: "theme.light")
    static let themeDark = Self(rawValue: "theme.dark")

    static let cloudAuthenticated = Self(rawValue: "cloud.status.authenticated")
    static let cloudUnauthenticated = Self(rawValue: "cloud.status.unauthenticated")
    static let cloudPending = Self(rawValue: "cloud.status.pending")
    static let cloudTitleFormat = Self(rawValue: "cloud.status.title-format")

    static let androidStartupFailureTitle = Self(rawValue: "android.error.startup.title")
}
