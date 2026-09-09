# OKVideoMac 0.6.1（Build 101）Release Notes

日期：2026-09-09 · Tag：`v0.6.1`

## 版本定位

0.6.1 是 0.6.0 的补丁版本，重点是可选 Android Compatibility 的存储管理与安全组件卸载。
正式 DMG 已通过 Release 构建、Developer ID 签名、Apple 公证（`Accepted`）、
Staple、Gatekeeper 与安装 smoke test。

## Android Compatibility 存储管理

- 分类查看托管组件、安装缓存、Android 用户数据与备份的空间占用。
- 不再需要时，可卸载由 OKVideoMac 管理且能够识别的 Android 组件。
  确认框根据实际安装内容显示预计释放空间，不承诺固定容量。
- 卸载前先停止并确认本应用的 Android 会话已退出；正在使用 External 模式也遵循此规则。
  不能确认停止时不执行卸载。
- 默认保留 Android AVD / userdata、登录状态、backing/encryption 文件、Android home、
  私有 `adbkey` / `adbkey.pub`、用户数据备份和 `runtime-selection.json`。
- External SDK 永远不会进入删除目标；需要时可重新安装 Managed components。
  当前没有“删除 Android 用户数据”入口。
- 中断的维护事务可恢复，未清理完的文件会显示待清理状态，便于继续处理。
  本功能提供简体中文与英文界面。

## 修复与文档

本次包含的维护保护会在 AVD 修复回退未能恢复文件时保留备份；明确的 External 模式
不再套用共存 Managed generation 的 AVD 上下文。播放、Provider 与 Xtream 的功能范围不变。
中英文 README 同步版本与功能事实，并在首屏、Provider 表和兼容文档中突出 Native Xtream。

Native Xtream 已在 **0.6.0** 引入，支持认证、Movies、Series、电影/剧集搜索和 Basic Live；
并非本补丁新增。Xtream EPG、回看/时移、`direct_source`、Stalker/Portal 和 iCloud 同步
不属于当前公开支持范围。

## 验证与系统要求

Apple Silicon（`arm64`），macOS 12.0 或以上；Android 只用于部分 Java/Dex Provider。
维护者反馈真实 Emulator 场景已人工验证，未发现明显问题；这属于人工反馈，不计入自动测试。
本轮不执行用户真实 Runtime 卸载。自动测试及 Release 验证结果见
[验证记录](RELEASE_VALIDATION_0.6.1.md)。

技术边界见 [Android Managed 卸载说明](ANDROID_MANAGED_UNINSTALL.md)，
公开资产已通过 [DMG 发布流程](DMG_RELEASE_PROCESS.md)。既有 v0.6.0 tag 和发布记录不变。

发布提交：`25155f52fb8c416f3245c9a829a93175dec9857b`。Release 附件中的发布说明和
源码保留构建时快照；本页与 GitHub Release 正文补充后续公证及发布结果，不修改原始资产哈希。

---

# OKVideoMac 0.6.1 (Build 101)

Date: 2026-09-09 · Tag: `v0.6.1`

## Patch scope

0.6.1 adds storage management and safe component uninstall to optional Android
Compatibility. The release DMG passed Release packaging, Developer ID signing,
Apple notarization (`Accepted`), stapling, Gatekeeper and installation smoke tests.

## Android Compatibility storage management

- View categorized storage usage for managed components, installation cache,
  Android user data and backups. The confirmation estimates reclaim from the
  recognized installation, rather than promising a fixed amount of space.
- Safely uninstall Android components managed by OKVideoMac after its Android
  session has been confirmed stopped. This also applies while using External mode;
  uninstall is refused when shutdown cannot be confirmed.
- Preserve AVD/user data, login state, backing/encryption files, Android home,
  private ADB keys, user-data backups and runtime selection by default.
- External Android SDKs are never uninstall targets. Managed components can be
  reinstalled later; a separate Android user-data deletion action is not offered.
- Resume interrupted maintenance or pending cleanup. English and Simplified Chinese
  interfaces are provided.

## Fixes and documentation

The included maintenance safeguards preserve AVD backups when repair rollback
cannot restore their files. Explicit External mode no longer inherits a coexisting
Managed generation's AVD context. Playback, Provider and Xtream scope is unchanged.
English and Chinese READMEs now align their version and capability descriptions,
with existing Native Xtream support visible on the first screen and in provider tables.

Native Xtream was introduced in **0.6.0**, including authentication, Movies, Series,
Movie/Series search and Basic Live. Xtream EPG, catch-up/timeshift, `direct_source`,
Stalker/Portal and iCloud sync are outside the current supported scope.

## Verification and requirements

Apple Silicon (`arm64`) and macOS 12.0+ are required. Android is optional and only
used by selected Java/Dex providers. The maintainer reports successful manual
verification with a real Emulator; this is separate from automated test results.
This finalization does not uninstall the user's real Runtime. See the
[validation record](RELEASE_VALIDATION_0.6.1.md),
[managed uninstall design](ANDROID_MANAGED_UNINSTALL.md) and
[DMG release process](DMG_RELEASE_PROCESS.md). The existing v0.6.0 tag and release
history remain unchanged.

Release commit: `25155f52fb8c416f3245c9a829a93175dec9857b`. Attached notes and source
archives preserve the build-time snapshot. This page and the GitHub Release body
record subsequent notarization and publication results without changing asset hashes.
