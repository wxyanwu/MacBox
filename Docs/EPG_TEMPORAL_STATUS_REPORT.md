# Imported/XMLTV 节目单时间状态修正

日期：2026-09-11。仅修正 7A.1 imported/XMLTV 的状态表达，不修频道匹配或上游数据。

## 结果与边界

已实现、完成专项/全量自动测试及本地 Release 编译。停止在本轮指定的验证边界：未 commit、push、tag、安装、替换 Desktop App、生成正式 DMG、发布或进入 7B；版本仍为 0.6.1 / Build 101。

**此前 Fzrn0M 本地验收 App 没有被替换，仍不包含本轮修正。** 本轮 Release 产物只作编译验证，未重新执行验收打包与 bundle 校验，不将 DerivedData App 当成已验证安装包交付。

## 状态语义

| 已有 snapshot 状态 / 数据 | 顶部展示 |
| --- | --- |
| 下载或准备中 | 保留原加载中状态 |
| 成功取得非空 XMLTV，maxProgrammeEnd > now | 节目单已载入 |
| 成功取得非空 XMLTV，maxProgrammeEnd <= now | 节目单已过期，等待更新 |
| 成功取得空 programme 表åΩΩ保留原失败/缓存刷新失败提示，优先于上述成功状态
 |

“已载入”只说明表存在尚未全部结束的时间范围，**不保证某频道匹配成功，也不保证每个时刻都有节目**。只有未来节目的表也显示已载入，当前节目仍为空。没有新增全目录 matcher 扫描。

Cache freshness 和 programme coverage 继续独立。新下载的昨日表仍可具有 `.fresh` availability，但展示为已过期；stale 表也可能仍有有效当前节目。Repository 的 freshness、TTL、backoff、single-flight、缓存格式和刷新行为均未更改。

针对本次样本的固定测试使用 `20260910231000 +0800` 至 `20260910235900 +0800`，并在 `2026-09-11 00:08:29 +08:00` 判定过期。没有平移时间、延长末档节目或伪造 Now/Next。

## 实现位置

以下路径相对于 `OKVideoMac/macOS/OKVideoMac/`：

- `Packages/OKVideoKit/Sources/OKVideoCore/Live/EPGModels.swift:60`：`EPGSnapshot.xmltvMaxProgrammeEnd`，仅在 imported snapshot 初始化时从 programme end 计算一次最大值。Native 为 nil；没有写入持久缓存。
- `App/AppState.swift:4319`：`LiveSourceEPGStatus` 保存时间边界，`presentation(at:)` 用 O(1) 比较生成状态。
- `App/AppState.swift:17644`、`:17687`：`refreshEPGDemand` 的 imported 已有 snapshot / 新 snapshot 两个分支使用同一状态映射；原请求、等待和失败判定不变。
- `Features/Live/LiveView.swift:261`：顶部标签映射。
- `Features/Live/LiveView.swift:796`：单个 imported 顶部子视图复用 `EPGTimelineSchedule` 和 `LiveEPGState` 的 tick 信号。时间边界只重算展示，不发请求；不将 programme clock 提升到整个 Live grid。
- `Resources/Localizable.xcstrings`：三条状态的中英文本。
- `Tests/OKVideoMacTests.swift:13`：12 项 App 覆盖测试。
- `Packages/OKVideoKit/Tests/OKVideoCoreTests/EPGModelTests.swift:5`：2 项 Core 元数据测试。

本轮共改动上述 6 个源码/测试/资源文件，并新增本报告。工作树已有的 7A/7A.1、验收打包和用户 DemoSource 改动保持原样。

## 验证结果

上轮记录的基线：Core 301 passed；App 731 total = 724 passed + 7 skipped。本轮新增 Core 2 项、App 12 项。

| 门禁 | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| EPG / XMLTV Core 专项 | 46 | 0 | 0 |
| App coverage + EPGIntegration 专项 | 22 | 0 | 0 |
| OKVideoKit 全量 | 303 | 0 | 0 |
| Xcode Debug App 全量 | 735 | 0 | 8 |

专项属于全量的子集，不重复累计。`git diff --check` 通过；Release arm64 build 通过。

新增覆盖：fresh/current、fresh/expired、stale/current 独立性、空表、end == now、+0800 跨午夜、新日表更新、embedded Pluto 形状的固定 fixture、Now/Next 不变、已有 clock boundary/wake 信号重算、future-only、失败状态不误报。Core 另覆盖无序 programme 最大结束时间，以及 empty/Native 元数据行为。

Debug 最初两次尝试在测试宿主启动阶段失败（LaunchServices IDELaunchErrorDomain 20），不是测试断言失败，也未计为 passed。当前验收 App 正在运行，工程设置禁止相同 bundle ID 多实例。后续仅在 xcodebuild 命令行对临时 Debug 产物使用独立 bundle ID `com.okvideomac.coverage.$(PRODUCT_NAME:rfc1034identifier)` 和本地 ad-hoc 签名，专项及全量均成功。没有修改工程的 bundle ID 或终止验收 App。Release 使用正式工程标识、`CODE_SIGNING_ALLOWED=NO` 编译。

8 项 skipped：2 项 Contract B 外部样本/配置未提供、4 项需要显式开启的真实 Android 生命周期/External/app-exit 集成、2 项 Native Xtream 公网/renderer gate。比上轮多跳过的是真实 Android app-exit gate；本轮独立测试配置没有开启它，没有为降低 skipped 数量而运行会涉及真实运行时的额外测试。

编译仍有既有 warning：WebKit Sendable、Swift 6 并发迁移提示、OpenGL/菜单 API 弃用、部分无效 await/try 或推断类型提示，以及脚本阶段未声明输出。本轮未扩大范围清理这些 warning。

日志和结果：

- `/private/tmp/okvideomac-coverage-focused.log`
- `/private/tmp/okvideomac-coverage-core-full.log`
- `/private/tmp/okvideomac-coverage-app-focused-isolated.log`
- `/private/tmp/okvideomac-coverage-app-full.log`
- `/private/tmp/okvideomac-coverage-app-full.xcresult`
- `/private/tmp/okvideomac-coverage-release.log`
- Release 编译目录：`/private/tmp/okvideomac-coverage-release/Build/Products/Release/`

## 回归范围与未自动证明的事项

与修改前冻结源码逐文件比对，`EPGRepository`、`XMLTVChannelMatcher`、`XMLTVService`、Native `XtreamEPG` 和 `PlayerView` 未变。`AppState` 的差异仅为状态类型和两个 imported 状态赋值点；`playLive`、`switchLiveChannel`、网络调度和播放 URL 均未变。

没有新增 per-card task、每频道 XMLTV 下载、全目录匹配扫描、retry loop 或任何刷新频率变化。顶部子视图每次时间判断仅比较一个日期。

本轮没有重新请求真实外部 XMLTV 或 Pluto；Pluto 回归是 embedded resolution 的固定 fixture，不冒充真实网络验证。没有执行实际 Mac sleep/wake、滚动流畅度、首帧或快速换台的 UI/E2E 验收；自动测试验证的是时间计算与已有时钟信号，不是完整系统睡眠体验。

## 后续人工验收要点

待另行生成包含本轮修正、通过打包校验的 Release 候选后：

1. 仍使用昨日 XMLTV：顶部应为“节目单已过期，等待更新”，卡片保持无当前/下一节目。
2. 提供覆盖现在的新表：顶部变“节目单已载入”；原 Now/Next 正常。
3. 空表显示“节目单暂无数据”；断网使用旧缓存时保留原刷新失败/缓存提示。
4. 留在页面跨过最后节目 end 或睡眠后恢复，确认顶部过期；检查播放、换台不受影响。

修正文案不会为昨日 XMLTV 补出今天节目；今天节目仍需上游提供有效数据。
