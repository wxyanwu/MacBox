# OKVideoMac 0.6.0（Build 100）Release Notes

发布日期：2026-09-09 · Tag：`v0.6.0`

## Highlights

0.6.0 新增原生 Xtream-compatible API 接入，将电影、剧集、搜索和基础直播接入
同一个 macOS 客户端，并提供简体中文与 English 界面。原有 TVBox/CatVod、
CatPaw 风格 Node、QuickJS 和可选 Android `csp_` 路径继续保留。

## Native Xtream

- 分开填写服务器地址和账号；凭据按 Provider 保存到 macOS Keychain。
- 识别 Active、过期、禁用和无效账号状态；异常响应不会被默认为正常账号。
- Movies：分类、分页列表、详情和播放。空 metadata 数组可使用目录中已有信息。
- Series：分类、列表、详情、季/集导航与连续播放。
- Search：电影与剧集本地索引，并接入 App 的聚合搜索。
- Basic Live：分类、频道、搜索、收藏/隐藏、刷新和播放；失效时仅尝试同一频道的
  TS/HLS 格式候选，不跳到无关频道。
- 历史、收藏和备份保存不透明资源引用，避免保存带账号的完整播放 URL。
  导出配置不包含账号密码，恢复后需要重新输入。

## Playback

- Native Xtream Live 为静态 HTTP 代理和 HTTPS CONNECT 增加独立决策，改善 API
  可访问、媒体却无法连接的情况。常规 302 媒体重定向仍由 libmpv 处理。
- Native Live 最长加载期限调整为 60 秒。普通导入 Live 的 8 秒、普通 VOD 的
  30 秒策略保持不变。
- 切台、加载中取消、关闭和再次播放使用请求所有权与播放器实例隔离，防止旧请求
  影响新播放，或把 Native Live 的网络参数带入其他 Provider。
- 备用 HLS 尝试可对已识别的大型 master 做受控选择，保留对应音频、字幕和
  closed captions。检查有独立总时限和大小限制，未知语义保留原播放方式。

## Localization

- 简体中文与 English 的 String Catalog、界面文案和日期显示。
- “跟随系统 / 简体中文 / English”语言选择会保存，变更后可重启生效。
- 首次启动默认跟随系统首选语言的第一项；非简体中文语言（包括繁体中文）回退英语。
- 重启助手等待旧进程退出，避免重复启动和语言切换退出互相等待。
- Provider 返回的影片、频道和人物名称保持原文。

## Runtime / Existing Providers

原有 Native CMS、TVBox/CatVod 风格 QuickJS、CatPaw 风格 Node、普通直链、
本地文件、M3U/TXT/JSON Live、XMLTV、Range/seek 和可选 Android Bridge 保持
各自兼容边界。Managed Runtime 与 External SDK 两种 Android 模式继续保留；
普通 Native、QuickJS、Node 与直播使用不需要 Android。

## Fixes

- 整合来源配置入口，保留 TVBox、CatPawOpen 风格与 Xtream 的实际导入能力。
- 修复选集、音轨、字幕和播放设置面板的高度与内容布局，适应普通窗口、缩放窗口及全屏。
- 改善浏览返回按钮的完整点击区域和路由更新，以及配置切换时的状态隔离。
- 修复私有 Android 目录使用系统路径别名时，退出校验误拒绝关闭自身 Emulator 的问题。
- 修复 Xtream `get_vod_info` 的 `info: []` 兼容缺陷，仍拒绝真正的错误 metadata 类型。

## Known limitations

- Xtream-compatible 面板之间存在 API 和媒体差异，不保证所有服务商兼容。
- Native Xtream 不提供 EPG、catch-up/timeshift、`direct_source`、带凭据的 Live
  导出或多个 Xtream Live 来源聚合。
- 代理支持不等于完整继承 macOS 的 PAC、SOCKS、认证代理和逐 URL/CDN 路由。
- 复杂 multivariant HLS 仍可能初始化较慢。受控回退只作用于已有的备用 HLS 尝试，
  可选择最高 1080p/60 的 H.264/AAC 组合，不是通用清单重写或自适应码率实现。
- Java/Dex、QuickJS 和 Node 仍是已实现接口的兼容子集；Android API 35 的真实
  Emulator 证据来自 Apple M1 / macOS 14.8.8，不代表其他 macOS 版本均完成实测。
- 不内置第三方影视源、账号、Cookie、解析服务或 DRM 密钥。

## System requirements

Apple Silicon / arm64，macOS 12.0 或更高版本。不提供 Intel 或 Universal Binary。
Android Runtime 仅用于选定的 Java/Dex `csp_` 兼容路径。

---

# OKVideoMac 0.6.0 (Build 100)

Release date: 2026-09-09 · Tag: `v0.6.0`

## Highlights

Native Xtream-compatible APIs now provide Movies, Series, combined catalog search
and Basic Live. English and Simplified Chinese interfaces include a persistent
language choice and a restart/relaunch flow.

## Native Xtream

Account credentials are stored per provider in macOS Keychain. Authentication
rejects expired, inactive and malformed account responses. Movies include categories,
lists, details and playback; Series add seasons, episodes and continuous playback.
Movie and Series indexes participate in aggregate search. Basic Live includes
categories, channels, search, favorites/hiding, refresh and bounded same-channel
TS/HLS recovery. History and backups retain opaque references, not credential-bearing
playback URLs; imported account configurations require credentials to be entered again.

## Playback

Native Live uses isolated static HTTP proxy/HTTPS CONNECT handling, native media
redirects and a bounded 60-second load deadline. Imported Live retains its 8-second
policy and ordinary VOD its 30-second policy. Request ownership and separate player
instances protect channel changes, cancellation, closing and cross-provider playback.
A conservative fallback for recognized large HLS masters preserves associated audio,
subtitles and closed captions and has independent time and response-size bounds.

## Localization

English and Simplified Chinese String Catalog resources cover application-owned UI.
Language preferences persist and take effect after restart. First launch examines the
first system-preferred language; unsupported languages, including Traditional Chinese,
resolve to English. Provider-supplied content names remain unchanged.

## Runtime / Existing Providers

Native CMS, selected TVBox/CatVod QuickJS and CatPaw-style Node interfaces, optional
Android `csp_`, local/direct media, imported M3U/TXT/JSON Live, XMLTV and seek behavior
retain their existing scope. Managed Runtime and External SDK remain separate choices.

## Fixes

Source setup is grouped by the supported entry points. Player utility panels fit their
content across window sizes. Browser back controls retain a full click target and the
current navigation action. Empty Xtream VOD metadata arrays fall back to catalog data
while malformed nonempty metadata remains rejected. Android shutdown now compares both
canonical paths when verifying private AVD files, avoiding false ownership rejection
for system directory aliases while retaining process and directory boundaries.

## Known limitations / System requirements

Server differences still apply. Native Xtream EPG, catch-up/timeshift, `direct_source`,
credential-bearing Live export and multi-provider Live aggregation are not implemented.
Proxy support does not cover all PAC, SOCKS, authenticated-proxy or per-CDN routing
semantics. Complex HLS can still start slowly; the existing backup-HLS attempt only
selects a conservative H.264/AAC combination up to 1080p/60. This is not universal
HLS or provider compatibility. Android/Spider support remains a selected subset.
Apple Silicon (`arm64`) and macOS 12.0+ are required; Intel and Universal releases are
not provided. Android is optional and only used for selected Java/Dex providers.
