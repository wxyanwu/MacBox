# EPG 7A.1 Implementation Report

日期：2026-09-10。范围：外部 XMLTV、全局默认、Source override、安全名称匹配；仍处于 7A 人工验收阶段。

## 交付状态与停止点

源码实现及自动回归已完成；经用户另行授权，本地验收打包入口也已完成。**独立 Release 验收候选已通过完整打包、源码对应、安全扫描、SBOM、bundle 和签名校验，现停止等待人工体验，不进入 7B。**

已实际执行 `Scripts/package-app.sh --mode local`。脚本完成 Release clean build 后，在源码归档阶段退出：`Source releases require a clean worktree.`

默认流程通过 `--commit HEAD` 生成对应源码索引；其 clean-worktree 门禁保持不变。用户随后授权了不依赖 commit 的独立本地验收入口。新增入口从当前源码的冻结副本构建，通过逐文件 SHA-256 绑定源码，明确声明 `git_commit: null`，而不是绕过归档或将旧 7A 的索引冒充本轮索引。

已验证独立 App（没有安装/替换 Desktop）：

`/private/tmp/OKVideoMac-Acceptance.Fzrn0M/Artifacts/OKVideoMac.app`

已保存 ZIP 和配套源码/校验材料：`build/EPG71Acceptance-20260910/SourceRelease/`。其中 `OKVideoMac-0.6.1-macOS-arm64.zip` 的 SHA-256 为 `cc96e05b85c88cffe3cbab42d1092ec921989666caef7249b2317bc70f68a18a`。复制后的 13 项 SHA256SUMS 全部通过。先退出旧 App，再打开上述独立候选；不是原来的 DerivedData 编译产物。

入口为 `Scripts/package-local-acceptance.sh`，说明见 `Docs/LOCAL_ACCEPTANCE_PACKAGING.md`。快照共 483 个输入文件，清单摘要 `fdadff15b98d79a29cd8dfd6e32a7e6d0b64c9bba09b571d47a0c7ac99d19880`；打包结束后逐项确认当前选定源码仍与该快照一致。base HEAD 仅作参考，未创建任何 commit。
å
没有 commit、push、tag、GitHub Release、正式 DMG、Desktop 替换、公告或 7B。版本仍为 **0.6.1 / Build 101**。所有源码修改保留在当前工作树。

## A. 基线、架构与数据流

- 起始 HEAD：`14dd3a584f49bdb67a5b7edd25c9980f77f480e2`，工作树已有 7A 未提交实现和用户 DemoSource 文件。本轮没有回滚或提交它们。
- 本轮修改前重新运行 OKVideoKit：275 passed / 0 failed，5.821 秒。7A 原报告的 App 基线是 726 total / 719 passed / 7 skipped；本轮没有把历史报告冒充新测量。
- 单一 `EPGRepository actor` 的实现完全复用；没有新增 Repository、programme 数据库或另一套缓存。继续复用 XMLTV parser、`XMLTVScheduleIndex`、`EPGSnapshot`、Now/Next 和 `LiveEPGState`，在其上扩展 aliases、匹配与 generation 门禁。
- Native Xtream adapter、播放器核心、Android Bridge 源码不变。
- `AppState.loadSettings` 读取配置；`resolvedEPGSource` / `epgRevision` 生成源级身份；原 `refreshEPGDemand` 异步下载和查询 Repository；`LiveEPGState.publish` 校验后供卡片的小粒度 Now/Next 子视图显示。

新增 `EPGPreferences`：总开关、默认 URL、按 Source UUID 保存的 `EPGSourcePreference`（automatic/custom/disabled、custom URL）。复用 SQLite Settings 中一个版本化值 `live.epg.preferences.v1`，没有修改 StoredLiveSource 表结构。旧数据库没有该 key、旧 JSON 缺字段，均解释为总开关开启、默认 URL 空、Source automatic。测试验证重开数据库后 round-trip，并验证原直播源 rawData 未改变。

M3U/import 解析规则：

| 条件 | 最终结果 |
| --- | --- |
| 总开关关闭 | 无 EPG，包括 Native short EPG |
| Source disabled | 无 EPG，不读取 embedded/global |
| Source custom | 仅 custom URL；无效输入不保存，不 fallback |
| Source automatic，有 embedded | embedded XMLTV |
| Source automatic，无 embedded | global XMLTV；global 空则无 EPG |
| Native Xtream，总开关开启 | 原 get_short_epg，不使用全局 XMLTV |

`x-tvg-url` 是本轮新增，**不是 7A 原有能力**。多字段优先级固定为 `tvg-url > url-tvg > x-tvg-url`（首个非空），保留两个旧字段之间的优先级；字段排列顺序不会改变结果。

### 缓存与生命周期

- 持久身份继续是 source kind + source UUID + SHA-256(最终 URL) + resource（XMLTV 为 `xmltv`；Native 为 stream ID）。缓存 key 不含明文地址或凭据。
- URL 改变得到不同 revision；同 URL 的不同 Source 仍隔离。
- `LiveEPGState` 新增独立、每源 UUID generation。配置失效立即清展示并废弃该 token；即使最终 URL 恢复相同，第一次的发布 token 也不再有效。
- App 调度 generation 拦截失效 waiter；Repository 既有 flight UUID 与取消检查拒绝旧结果进入内存/磁盘；展示层 generation 再次拒绝迟到发布。
- 已测试 A→B→A、enabled→disabled→enabled、automatic→custom→automatic；Repository 测试实际挂起旧请求，验证它不能覆盖新内存/磁盘或清掉新 flight。
- global 改动仅失效依赖 global 的源；embedded/custom/Native 的已有 snapshot 和 source token 保留。不重新下载每个频道的 XMLTV。
- 同一 Source 恢复同一 URL 后，可以由新 generation 读取此前已有效保存的同资源缓存；这不等于接受被取消的旧 flight。

## B. 设置 UI

入口：设置 → 直播源 → **EPG / 节目单**。

- 原生 Toggle：自动加载 EPG。关闭后失效当前展示与 generation，取消相关请求；不影响频道目录或直播播放。
- 原生 TextField：默认 EPG 地址。URL 是局部草稿，输入不更新配置、不触发网络；点击保存或提交才验证并持久化。
- 恢复默认保存为空。没有硬编码任何公共 EPG 地址。
- 每个导入源一枚“节目单…”按钮，打开原生 Picker/文本框的轻量编辑 sheet：自动、自定义、不使用。说明中明确展示 embedded → global → 无。
- custom 无效时保留原配置和输入草稿，sheet 不关闭；错误为通用、脱敏文字，同时在设置区域内显示，不依赖主浏览窗口的错误弹窗。
- 设置持久化完成后生效，保存期间禁用重复提交；删除 global 不影响 embedded/custom，关闭总开关才关闭全部 EPG。

## C. 安全频道匹配

新增不可变 `XMLTVChannelMatcher`。先按不同 XMLTV ID 汇总所有候选，再决定结果；不会根据节目是否恰好覆盖当前时间去消除歧义。

1. trim 后非空 tvg-id：精确、区分大小写的 ID 查询。未知 ID 为 unmatched；命中但没有当前节目仍使用该 ID，不找其他频道。
2. 没有 tvg-id：合并 display name、tvg-name 与 XMLTV display-name/aliases/id 的规范化候选。一个 ID 为 normalizedUnique，多个 ID 为 ambiguous，零个为 unmatched。
3. 通用 normalization 为 Unicode NFKC、首尾/连续空白和 POSIX 大写。不会通用删除标点、地区、数字或频道类型。
4. CCTV 1–17 的 `CCTV-1` / `CCTV 1` / `CCTV1` 确定性等价；`+` 保留。HD/高清/超清只生成受限的次级候选；候选合并后仍必须唯一。
5. XMLTV 同一 channel 的多个 display-name 保存为可选 aliases，旧缓存缺少 aliases 仍可解码。相同 ID 的多个 alias 不算歧义。

以下为实际执行过的**固定测试样本**，不是声称已访问用户的外部 EPG：

| M3U 输入 | XMLTV 样本 | 判断 |
| --- | --- | --- |
| CCTV-1，无 ID | 唯一 CCTV1 | normalizedUnique |
| CCTV-5，无 ID | 唯一 CCTV5 | normalizedUnique |
| CCTV-5+，无 ID | 唯一 CCTV5+ | normalizedUnique；只有 CCTV5 时 unmatched |
| CCTV-13，无 ID | 唯一 CCTV13 | normalizedUnique；只有 CCTV1 时 unmatched |
| 湖南卫视高清，无 ID | 唯一 id=hn/display-name=湖南卫视 | normalizedUnique |
| 湖南卫视高清，无 ID | hn=湖南卫视、hnHD=湖南卫视高清 | ambiguous，不返回节目 |
| display name=CCTV-1、tvg-name=CCTV2 | 分别指向 A、B | ambiguous，不取第一个 |
| 名称 CCTV-2、tvg-id=one | one 和 two 均存在 | exact one，ID 优先 |
| 名称 CCTV-1、tvg-id=missing | 只有 CCTV1 | unmatched，不名称兜底 |

**有意的行为收紧：非空 tvg-id 未命中后，旧的名称 fallback 被禁止。** 这可能使此前靠猜测纠错的少数源不再显示节目；不是“所有旧匹配行为完全不变”。正确 ID 的已有 M3U 路径仍保留。

## D. 测试与工程门禁

本轮新增 **31 项测试**：Core/Persistence 26 项（偏好 9、持久化 1、匹配 13、Repository 2、HTTP 1），App 5 项；原 7A 测试继续运行。

| 门禁 | 结果 |
| --- | --- |
| git diff --check | 通过 |
| OKVideoKit 全量 | 301 passed / 0 failed / 0 skipped |
| EPG/XMLTV/HTTP/LiveSource 专项 | 66 passed / 0 failed / 0 skipped（全量子集，不重复计数） |
| App EPG 专项 | 10 passed / 0 failed / 0 skipped（全量子集） |
| Xcode Debug App 全量 | 731 total：724 passed / 0 failed / 7 skipped |
| Release build | 通过；版本读取为 0.6.1 / 101 |
| 默认 package-app.sh | 仍保留 clean-worktree 门禁；原未提交工作树调用退出码 1 |
| 经授权的本地验收入口 | 通过，退出码 0；复用 package-app.sh 的完整本地校验链 |
| 新入口的工具测试 | 11 passed / 0 failed / 0 skipped；shell 语法及 diff 检查通过 |
| App、ZIP 解包 App、最终独立 App | 三次 bundle/严格签名校验通过；29 Mach-O、170 Maven 模块的 SBOM 校验通过 |
| 敏感信息扫描 | 签名前及最终源码/产物目录均零 findings |
| 已验证的新本地验收包 | 已交付独立 Release App + ZIP；没有 DMG 或安装动作 |

7 项 skipped 原因：2 项外部 Contract B 配置/样本未提供，3 项需显式真实 Android/AVD 生命周期测试，2 项需显式 Native Xtream 公网/renderer 门禁。它们不是 passed。候选是本地 ad-hoc Hardened Runtime 签名，不是 Developer ID 公证发行包；Gatekeeper assessment 标记 NOT TESTED，不计为通过。

warning 如实保留：构建脚本阶段未声明 outputs；已有 WebKit Sendable、Swift 6 actor/sendable 提示；OpenGL/菜单 API 弃用；已有无 throwing 调用的 try 提示。本轮未扩大范围修改这些文件以消除 warning。首次 EPG App 专项虽测试通过，但曾出现 xcresult 保存失败；后续独立结果路径的全量运行正常，不能把首次结果文件当成完整证据。

未执行：真实联通+外部 XMLTV 公网验收、Pluto 公网回归、真实 Native 账号联网 EPG、UI 自动点击/键盘输入端到端验收。没有填入或修改用户真实源/EPG URL，没有访问、记录测试凭据。固定 XMLTV、gzip、缓存、重定向策略和生命周期由自动测试覆盖，不冒充真实网络/设备体验。

性能边界：保持浏览需求最多 8 个频道、Repository/展示快照最多 32 项及 400,000 programme 总预算；没有 GeometryReader/PreferenceKey 可见性体系、每卡请求或每卡 task。15 秒和 programme boundary 的时钟仍局限于 Now/Next 子视图。测试覆盖快照上限与睡眠后按新时间重算，但**没有测量或保证真实滚动 FPS、首帧和快速切台延迟**；测试运行秒数不作为性能 benchmark。

安全边界：下载 32 MiB、gzip 解压 64 MiB、单表 programme 200,000、缓存文件 80 MiB、原磁盘淘汰和 0600/0700 权限均保留；XML 外部实体仍禁用。新增 XMLTV display-name 总量上限 200,000。XMLTV 请求允许 CDN 重定向但逐跳禁止 HTTPS→HTTP，Native 更严格的同源规则不变。没有普通日志原始 payload 或高频匹配日志。外部 URL 属于用户配置，可能带 token，保存在已有 Settings 中；不应分享该配置原文。Native credential store 未改动。

## E. 修改范围与回归风险

- **未修改 Player core、playLive、switchLiveChannel 的等待链**；EPG 不在播放首帧或换台的 await 链中。
- LiveChannel.id、原 M3U stream URL 与源 rawData 不变；未新增每卡网络请求。
- 已有 embedded M3U 继续优先；删除 global 不影响它；上述非空 ID 禁止 fallback 是唯一有意收紧的匹配兼容性行为。
- Native 的配置解析、credential store、get_short_epg adapter 不变，仅接受总开关控制。
- 未实现 Full Guide、catch-up、timeshift、programme SQLite、alias 大库、手工映射 UI 或系统后台 daemon。
- 与本轮起始 diff 逐文件对照：PlayerView、AppEnvironment、OKVideoMacApp、XtreamClient/DTO/SiteProvider、check-doc-status.sh 以及用户 Docs/DemoSource/README.md 的既有修改均未被本轮改动。相对 HEAD 的总 diff 包含旧 7A，不能全部归因于 7A.1。

关键代码（相对 `OKVideoMac/macOS/OKVideoMac`）：

- `Packages/OKVideoKit/Sources/OKVideoCore/Live/EPGPreferences.swift`：模型、验证、resolution、URL revision。
- `Packages/OKVideoKit/Sources/OKVideoPersistence/Database/EPGPreferencesStore.swift`：轻量持久化。
- `Packages/OKVideoKit/Sources/OKVideoCore/Live/LiveSourceParser.swift:96`：三个头字段确定性优先级。
- `Packages/OKVideoKit/Sources/OKVideoCore/Live/XMLTVChannelMatcher.swift` / `LiveModels.swift` / `XMLTVParser.swift`：匹配、索引、aliases。
- `App/AppState.swift:17468`：保存；`applyEPGPreferences`：失效；`refreshEPGDemand`：异步加载与 generation 校验。
- `Features/Live/LiveView.swift:715`：prepare/publish generation 门禁；既有 Now/Next 小粒度视图。
- `Features/Settings/SettingsView.swift:1349`：全局和每源 EPG 设置。
- `Packages/OKVideoKit/Sources/OKVideoCore/Networking/URLSessionHTTPClient.swift` / `Live/XMLTVService.swift`：XMLTV no-downgrade 策略；普通网络请求默认策略不变。

## F. 证据与人工验收

日志均在本地临时目录：

- `/private/tmp/okvideomac-epg71-baseline.log`
- `/private/tmp/okvideomac-epg71-resolution-tests.log`
- `/private/tmp/okvideomac-epg71-matching-tests.log`
- `/private/tmp/okvideomac-epg71-full-core.log`
- `/private/tmp/okvideomac-epg71-final-focused.log`
- `/private/tmp/okvideomac-epg71-lifecycle-app.log`
- `/private/tmp/okvideomac-epg71-final-app.log` / `/private/tmp/okvideomac-epg71-final-app.xcresult`
- `/private/tmp/okvideomac-epg71-package.log`（Release clean build + 打包阻塞）
- `/private/tmp/okvideomac-epg71-final-release.log`（最终 UI 错误反馈补充后的 Release 编译）
- `build/EPG71Acceptance-20260910/package.log`（已授权独立快照的完整成功打包）
- `build/EPG71Acceptance-20260910/SourceRelease/`（ZIP、精确源码、锁定第三方源码、索引、SBOM、APK 与 SHA256SUMS）

人工步骤见同目录 `EPG_7A1_MANUAL_ACCEPTANCE.md`。**请使用上述已验证的新独立 Release 候选，不要拿既有 7A App 验收 7A.1。** 本轮未自动启动候选访问真实源；真实联网、滚动/首帧/快速换台、睡眠恢复仍等待人工验收。
