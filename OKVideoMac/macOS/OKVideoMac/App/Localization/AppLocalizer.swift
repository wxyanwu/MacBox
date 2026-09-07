import Foundation

struct AppLocalizationBundleSelection: Sendable {
    let requestedLanguage: AppLanguage
    let resolvedLanguage: AppLanguage
    let bundle: Bundle
    let usedEnglishFallback: Bool
}

enum AppLocalizationBundleResolver {
    static func selection(
        for language: AppLanguage,
        in baseBundle: Bundle = .main
    ) -> AppLocalizationBundleSelection {
        if let bundle = localizedBundle(language, in: baseBundle) {
            return AppLocalizationBundleSelection(
                requestedLanguage: language,
                resolvedLanguage: language,
                bundle: bundle,
                usedEnglishFallback: false
            )
        }
        if let englishBundle = localizedBundle(.english, in: baseBundle) {
            return AppLocalizationBundleSelection(
                requestedLanguage: language,
                resolvedLanguage: .english,
                bundle: englishBundle,
                usedEnglishFallback: true
            )
        }
        return AppLocalizationBundleSelection(
            requestedLanguage: language,
            resolvedLanguage: .english,
            bundle: baseBundle,
            usedEnglishFallback: true
        )
    }

    private static func localizedBundle(
        _ language: AppLanguage,
        in baseBundle: Bundle
    ) -> Bundle? {
        guard let path = baseBundle.path(
            forResource: language.resourceName,
            ofType: "lproj"
        ) else { return nil }
        return Bundle(path: path)
    }
}

final class AppLocalizer: @unchecked Sendable {
    static let shared: AppLocalizer = {
        let mode = AppLanguagePreferenceStore().load()
        let language = AppLanguageResolver.resolve(mode: mode)
        return AppLocalizer(language: language)
    }()

    let language: AppLanguage
    let locale: Locale
    let resourceBundle: Bundle
    let usedEnglishFallback: Bool

    init(language: AppLanguage, baseBundle: Bundle = .main) {
        let selection = AppLocalizationBundleResolver.selection(
            for: language,
            in: baseBundle
        )
        self.language = selection.resolvedLanguage
        locale = selection.resolvedLanguage.locale
        resourceBundle = selection.bundle
        usedEnglishFallback = selection.usedEnglishFallback
    }

    func string(
        _ key: L10nKey,
        fallback: String? = nil,
        arguments: [CVarArg] = []
    ) -> String {
        let safeDefault = fallback ?? key.rawValue
        let localized = NSLocalizedString(
            key.rawValue,
            tableName: "Localizable",
            bundle: resourceBundle,
            value: safeDefault,
            comment: ""
        )
        guard !arguments.isEmpty else { return localized }
        return String(format: localized, locale: locale, arguments: arguments)
    }
}

enum L10n {
    static var language: AppLanguage { AppLocalizer.shared.language }
    static var locale: Locale { AppLocalizer.shared.locale }

    static func string(
        _ key: L10nKey,
        fallback: String? = nil,
        _ arguments: CVarArg...
    ) -> String {
        AppLocalizer.shared.string(
            key,
            fallback: fallback,
            arguments: arguments
        )
    }

    static func string(
        _ rawKey: String,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        AppLocalizer.shared.string(
            L10nKey(rawValue: rawKey),
            fallback: fallback,
            arguments: arguments
        )
    }
}
