# Localization

OKVideoMac ships English (`en`) and Simplified Chinese (`zh-Hans`) resources. The UI language setting stores the stable values `system`, `en`, or `zh-Hans` under `OKVideoMac.UILanguageMode.v1`; changing it takes effect after an app restart. Unsupported system languages resolve to English.

Application-owned copy lives in `Resources/Localizable.xcstrings` and is loaded through `L10n`/`AppLocalizer`. New UI text must use a semantic key, provide an English fallback, and include complete English and Simplified Chinese translations. Counts that vary grammatically use String Catalog plural variations, and user-visible dates use `L10n.locale`.

Persisted identities and business logic must not use translated labels. Store stable IDs and derive display text separately. Provider-supplied titles, people, channel names, stream names, brands, and server content remain unchanged. Common runtime failures are mapped to localized user-facing categories; redacted original details remain available to diagnostics.

Before shipping localization changes, verify both language bundles, placeholder parity, English singular/plural behavior, language preference isolation, Debug tests, and the packaged Release app in System, Simplified Chinese, and English modes.
