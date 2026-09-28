# MacBox

**A TVBox-compatible player for Mac**

**Supports Android TVBox subscription configurations**

English | [简体中文](README_zh-CN.md)

MacBox is an independently maintained project based on
[OKVideoMac](https://github.com/yaolin-dev/OKVideoMac), focused on Android TVBox
configuration compatibility, playback stability, and a native Mac experience.
OKVideoMac is the code origin; Android TVBox is the compatibility target.
MacBox is maintained and released independently and is not an official upstream build.

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple&logoColor=white)
[![GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)

## Current status

- Current app version: 1.0.0 (Build 102)
- Upstream baseline: OKVideoMac 0.6.1, commit `9970e2c`.
- Product branch: `main`. The application and installers are named MacBox with independent version numbering; a new MacBox icon is included.
- Development and device validation currently focus on Apple Silicon Macs; the minimum deployment target is macOS 12.0.
- Intel Macs, iPhone, and iPad have not completed adaptation and validation.

## Features and improvements

- VOD and live TV with Android TVBox configurations and inherited Xtream and M3U/XMLTV support.
- Native Swift/SwiftUI/AppKit interface and libmpv playback; selected JavaScript providers use QuickJS or Node.
- Java/DEX providers use a local Android Bridge and compatibility runtime on demand.
- Improved Gson-style configuration parsing, subscription requests, Android media format detection, and fresh playback retries.
- Settings layout fixes, isolated live-source validation progress, and prevention of idle display sleep during playback.
- CoreAudio callback lifetime protection for potential crashes during audio device changes.
- Losslessly compressed complete Android components: approximately 5.35 GiB to 1.82 GiB in the verified installation.
  This excludes Android user data, backups, and temporary installation space, and is not the initial download size.

Compatibility depends on each provider, plugin, network, and media service. Selected real samples
have passed search, detail, and playback checks; this does not guarantee every Android TVBox configuration or provider.

## Installation and use

Current builds are locally verified Release builds with ad-hoc signing. They are not
Developer ID signed or Apple-notarized upstream releases. Upstream downloads do not contain
this project's modifications. This README does not yet advertise a published MacBox installer.

1. Use a Release build made from this project.
2. Import your own TVBox configuration in Settings → VOD Sources; manage live sources in Settings → Live Sources.
3. Prepare Android compatibility components when prompted for Java/DEX providers. Android Studio is not required.
4. Select a provider, search or browse, and choose a playback line and episode.

Android components are not fully bundled for offline installation. Initial setup requires
network downloads and acceptance of the component licenses. The upstream internal Bundle ID
and data directories remain in use to preserve subscriptions, preferences, and history;
upstream and modified builds should not be treated as two apps with isolated data.

## Development and provenance

- Project repository: [wxyanwu/MacBox](https://github.com/wxyanwu/MacBox).
- Upstream repository: [yaolin-dev/OKVideoMac](https://github.com/yaolin-dev/OKVideoMac).
- `origin` is the independently maintained repository; `upstream` tracks the original project.
  Existing Git history and attribution are retained.
- [Build instructions](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Architecture](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [Android compatibility setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP_zh-CN.md)
- [Android storage and uninstall](Docs/ANDROID_MANAGED_UNINSTALL.md)
- [Historical changelog](CHANGELOG.md)

Source directories, the Xcode project, and some technical documentation retain the OKVideoMac name.
Historical releases, screenshots, and validation reports describe their recorded versions;
they are not automatically release or validation claims for the current MacBox project.

## Content and privacy

MacBox does not bundle media subscriptions, videos, accounts, cookies, parsing services, or DRM keys.
Only import configurations, scripts, and media that you trust and are entitled to use.
Third-party subscription plugins can execute code and access the network.

## License and copyright

Upstream-owned code is licensed under [GPL-3.0-only](LICENSE); this project continues under that license.
Copyright and license notices for Yao Lin, other contributors, and third-party components are retained.
Renaming the product does not change ownership of the original code.

See [source and modification notices](OKVideoMac/NOTICE.md),
[third-party notices](OKVideoMac/THIRD_PARTY_NOTICES.md), and
[binary/source mappings](Docs/BINARY_SOURCE_MAPPING.md).
