# 直播首播修复与 Release 验收（2026-09-14）

## 分支与输入身份

- 正确开发分支：`codex/epg-7a1-progress-ui`。
- 参考 HEAD：`14dd3a584f49bdb67a5b7edd25c9980f77f480e2`。当前成果包含此前未提交的 EPG、进度界面、身份迁移和播放会话改动，不能仅以 HEAD 代表完整源码。
- 依据：Git 分支切换记录、`PROGRESS_UI_IMPLEMENTATION_REPORT.md` 和最近的 9B 工作报告一致。没有切换分支、重置、创建提交或覆盖既有改动。
- 本次完整工作区冻结清单 SHA-256：`a85890720d1e805a8b1e8de977bd36f7d948e0c0604878a41586ec95b0c3a985`。
- 从该不可变快照重建 Android APK 与 macOS Release；不是从旧提交或旧 APK 打包。

## 根因与本次修改

此前实际运行包的三次启动日志中，媒体打开阶段占总启动时间约 95%–97%。Native Xtream 的 `.ts` 地址可以重定向为 HLS 主列表；FFmpeg 会在媒体打开阶段探测多个变体的子列表及媒体数据。原有优化仅在失败后的重试、声明为 m3u8 且变体数至少 12 时启用，无法覆盖首次播放及 Mux/Open 的小列表。完整原始诊断见 `LIVE_STARTUP_LATENCY_AUDIT_20260914.md`。

本次修改范围：

1. `App/AppState.swift`：Native Xtream 第一次播放即进行有界 HLS 识别与选择；取消、切台、关闭、关机均取消准备任务。准备时间计入原有启动预算。精简主列表加载失败时，同一请求在剩余预算内重试原始地址一次；不重试取消、失效请求及账户错误。
2. `OKVideoCore/Playback/LiveHLSStartupPreparer.swift`：单次 GET 跟随安全重定向，以响应内容识别 HLS，不依赖 `.ts`/`.m3u8` 后缀。5 秒总时限、256 KiB 大小上限、最多 5 次重定向；真实 TS 首块识别后取消请求，不等待连续流结束。仅完整收到的主列表可以参与选择。跨域剥离认证/Cookie，拒绝 HTTPS 降级，不持久化凭据或播放列表。
3. `OKVideoCore/Playback/HLSStartupSelection.swift`：支持至少 2 个变体的小列表和未声明 CODECS 的列表；保留选中变体关联的音轨、字幕和闭字幕组及绝对资源地址。不设置新的 1080p 上限；不支持的更高带宽变体、未知 HLS 扩展等保留原播放路径。
4. 新增/扩展核心和 App 测试。记录准备耗时、是否选中和变体数，不记录播放地址、账户或请求头。

未改动共享 HTTP 会话、EPG 下载策略、导入直播链路和全局播放器缓存参数。该修复针对已定位的 Native Xtream/HLS 首播探测开销，不承诺消除服务器首字节、代理/CDN、分片长度或关键帧等待。

## 已完成测试

- 核心 Release 测试：43 项通过，0 失败（HLS 选择、准备请求、HTTP、Xtream 直播目录）。
- App 播放器回归：9 项通过，0 失败（取消、代理、隔离、期限、释放顺序、恢复范围、账户失败策略、去重、TLS）。
- 公开网络与真实 App 渲染器验收：3 项通过，0 失败。Apple 验证 1920 宽画面和选中音轨；Mux 从 `.ts` 重定向首次选择并验证 1920 宽画面/音轨；Open 从 `.ts` 首次选择 6 变体列表并验证 640 宽画面/音轨。
- 三项网络测试在独立 Debug 测试宿主中运行，测试总时长分别为 19.275 / 9.088 / 9.592 秒，包含网络、渲染、时间线推进和清理，**不是点击到首帧的测量值**，不得与早先无渲染探针或用户操作时延直接比较。
- `git diff --check` 通过；冻结源码清单复验通过。
- 按用户最新要求，不操作用户直播界面做人工体验，不宣称已完成最终 Release 的人工首帧对比。

## Release 交付

本地交付沿用 v0.6.1 / build 101，使用源码清单摘要区分本次修复包；为 arm64 Release 配置、本地 ad-hoc 签名验收包，不是 Debug，也不是 Apple 公证的公开发行版。

- `package-app.sh --mode local --local-acceptance` 成功退出：Android Release APK 重建、macOS clean Release 编译成功。
- 29 个 Mach-O 签名/架构和 170 个 Maven 模块的 SBOM 检查通过；Hardened Runtime、本地签名、bundle 完整性通过。
- DMG 挂载验收、ZIP 解包验收、内外源码索引/APK 一致性、最终独立 App 校验通过。两轮敏感信息扫描均无发现。
- 交付目录：`OKVideoMac/macOS/OKVideoMac/Artifacts/LiveStartup-20260914-a8589072/`，含 DMG、ZIP、校验摘要、对应源码/许可证/第三方源码和 SBOM。
- DMG SHA-256：`342bb319c910d21d4011d5b3038f1d915ddddbaad2629b8c72b029224291dae0`。
- ZIP SHA-256：`4f41ed677c0b1d3508309a71b68592cce83d69fbfcc9c1162a8a8d12254bf1de`。

### 本机安装

桌面的 File Provider 同步服务给裸 App 自动附加 Finder 元数据，导致初次暂存副本签名检查失败。该副本未安装、未运行，已移到临时验收目录保留用于诊断；没有绕过校验或重新签署受损副本。

采用本机已有的 `Applications/OKVideoMac-Local/<源码清单摘要>/OKVideoMac.app` 安装布局，重新从已验证产物复制。此处 bundle、29 个 Mach-O 签名和逐文件字节比较均通过，再建立 `Desktop/OKVideoMac.app` 符号链接。通过桌面入口重新执行严格深度签名校验和字节比较也通过。原有旧版本和用户数据保留，未自动退出或启动用户应用。

测试时先退出正在运行的旧版本，再打开桌面 `OKVideoMac.app`。本次未改版本号，不应仅凭“0.6.1”字样判断是否打开修复包。
