import AndroidRuntimeKit
import Foundation

struct ManagedRuntimeFailurePresentation: Equatable, Sendable {
    let title: String
    let message: String
}

enum ManagedRuntimeFailurePresentationMapper {
    static func presentation(
        for failure: ManagedRuntimeInstallFailure,
        localizer: AppLocalizer = .shared
    ) -> ManagedRuntimeFailurePresentation {
        let titleKey: String
        let titleFallback: String
        let messageKey: String
        let messageFallback: String

        switch failure.code {
        case .network:
            titleKey = "android.install.error.download.title"
            titleFallback = "Android Compatibility Component Download Failed"
            messageKey = "android.install.error.network.message"
            messageFallback = "The download did not finish. Any resumable data was preserved. Check your network and try again."
        case .integrity:
            titleKey = "android.install.error.integrity.title"
            titleFallback = "Android Compatibility Component Verification Failed"
            messageKey = "android.install.error.integrity.message"
            messageFallback = "The downloaded file failed its integrity check and was not installed. Try again."
        case .diskSpace:
            titleKey = "android.install.error.disk-space.title"
            titleFallback = "Not Enough Disk Space"
            messageKey = "android.install.error.disk-space.message"
            messageFallback = "Free up disk space, then continue the installation."
        case .compatibility:
            titleKey = "android.install.error.compatibility.title"
            titleFallback = "Android Compatibility Component Is Unsupported"
            messageKey = "android.install.error.compatibility.message"
            messageFallback = "This Mac does not meet the system requirements for the current Android compatibility component."
        case .cancelled:
            titleKey = "android.install.error.cancelled.title"
            titleFallback = "Installation Cancelled"
            messageKey = "android.install.error.cancelled.message"
            messageFallback = "You can continue the next time Android content needs this component."
        case .invalidCatalog:
            titleKey = "android.install.error.catalog.title"
            titleFallback = "Android Compatibility Component Is Temporarily Unavailable"
            messageKey = "android.install.error.catalog.message"
            messageFallback = "The installation catalog failed security validation. No runtime files were downloaded or changed."
        case .invalidInstallation:
            titleKey = "android.install.error.invalid-installation.title"
            titleFallback = "Android Compatibility Component Installation Failed"
            messageKey = "android.install.error.invalid-installation.message"
            messageFallback = "The new environment was not activated. The previous runtime remains unchanged. Try again or export diagnostics."
        case .internalFailure:
            titleKey = "android.install.error.internal.title"
            titleFallback = "Android Compatibility Component Installation Failed"
            messageKey = "android.install.error.internal.message"
            messageFallback = "The installation was not activated. The previous runtime remains unchanged. Try again or export diagnostics."
        }

        return ManagedRuntimeFailurePresentation(
            title: localizer.string(
                L10nKey(rawValue: titleKey),
                fallback: titleFallback
            ),
            message: localizer.string(
                L10nKey(rawValue: messageKey),
                fallback: messageFallback
            )
        )
    }
}
