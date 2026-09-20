# Progress UI 方案 B — 本地验收报告

日期：2026-09-11。本轮仅改 Live EPG 和 History 的只读进度展示，以及用户要求的验收包 provenance/DMG 支持。当前不做 Git 收口，不进入公开发布。

## A. Git / Worktree

Branch Guard：PASS。

- Repository / worktree：`/Users/linyao/Documents/ok影视 mac 版本`。
- 原分支 `main`；经用户单独批准，从原 HEAD 原地执行一次 `git switch -c codex/epg-7a1-progress-ui`。
- 开发分支：`codex/epg-7a1-progress-ui`。
- 起始/结束 HEAD：`14dd3a584f49bdb67a5b7edd25c9980f77f480e2`；分支纠正后 HEAD 未改变，main ref 仍为同一原提交。
- 分支纠正后开发过程中换分支：NO。新本地分支：YES（仅本次明确授权的例外）。main ref/纠正后 main 开发：未改变/未继续。
- Files moved/stashed/reset：NO。Commit / push / merge / rebase / tag：NO。

切换前后保存了完整 binary diff、暂存区 diff、66 个未跟踪文件列表，以及全部 tracked/untracked 文件内容摘要；四组逐字节比较全部相同。

- before/after binary diff SHA-256：`e1ca473b4ad17ea494ba713552bbbe908a551e4440f0484f17366fccf4e7ee40`。
- before/after 全文件内容清单 SHA-256：`8caa33bcf66b433a04eed06d31f6bf6932402d7834a30a007c3be7f263071391`。
- 审计证据：`/private/tmp/okvideomac-before-branch-switch*` 与 `/private/tmp/okvideomac-after-branch-switch*`。

既有 7A / 7A.1 / temporal status 和用户修改完整保留。相对于本轮初始文件摘要，151 个受保护文件（Player、Core/EPG 数据层、用户 DemoSource）无变化。工作树本来就有 Player/EPG 等旧 diff，不能把这些旧 diff 算作本轮 Progress 修改。

## B. Progress UI

Live，`Features/Live/LiveView.swift` 的 `LiveNowNextView`：

- 原组件与最终组件均为系统 `ProgressView(value:)`。
- 已删除局部 `.tint(.accentColor)`，明确 `.progressViewStyle(.linear)`。
- 当前节目开始时间、进度、结束时间同行；时间 fixedSize + layoutPriority 优先保留完整宽度，进度使用中间剩余空间。
- stale 的“缓存”文字另起辅助行，不挤占时间/进度行。
- 保留原 TimelineView、EPGTimelineSchedule、progress calculation、Now/Next 和 programme boundary。
- 不新增 Timer、task、网络请求、AppState progress、GeometryReader、PreferenceKey、固定高度或动画。未加入 controlSize(.small)。

History，`Features/History/HistoryView.swift`：

- 删除 `HistoryProgressBar` 及 GeometryReader + 双 Capsule；删除固定 260×5、轨道透明度和 Accent 填充。
- 改为原生 linear ProgressView，左对齐、可收缩，maxWidth=200。200 点只是本次布局选择，不是 Apple 官方尺寸。
- `displayedProgress(position:duration:)` 是 HistoryView 内用于验证展示行为的纯函数，不是新共享 View/Model：保持 duration > 0 才显示、`min(max(position / duration, 0), 1)`。
- 0 正常显示、超出 duration 显示 1，duration <= 0 隐藏。
- 保留百分比 accessibilityValue；label 改为“观看进度 / Watch Progress”。无可见百分比或完成徽章。
- HistoryRecord、数据库和 position persistence 未改。

Player modified：NO。未分析或修改 Seek Bar、timeline、hover seek 等内容。

产品修改仅 LiveView、HistoryView、Localizable 和 App 测试四个文件；未新建通用 Progress 组件或样式。

## C. EPG 回归

EPG Engine modified during Progress task：NO。

7A、7A.1、external/global/per-source、x-tvg-url、strict matcher、generation、temporal status 的现有实现保持不变；对应 Core/App 专项及全量测试本轮重新执行。

时间状态仍是：有效非空表“节目单已载入”，所有 programme 结束后“节目单已过期，等待更新”，空 programme“节目单暂无数据”；本轮没有放宽匹配、伪造节目或改变 freshness。

## D. 本轮自动验证

| 验证 | Total | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| Progress 展示专项（新增） | 7 | 7 | 0 | 0 |
| Progress + App temporal/EPG 专项 | 29 | 29 | 0 | 0 |
| Core EPG/XMLTV 专项 | 46 | 46 | 0 | 0 |
| OKVideoKit 全量 | 303 | 303 | 0 | 0 |
| Xcode Debug App 全量 | 750 | 742 | 0 | 8 |
| acceptance packaging 单元测试 | 14 | 14 | 0 | 0 |

专项是全量子集，不重复累计。新增 7 项 App 测试（此前 743 项）和 3 项 packaging 测试（此前 11 项）。`git diff --check`、shell 语法检查通过。

History 覆盖 duration 为零/负、0%、25%、100%、超出时长、负 position 的展示 clamp。Live 布局测试组合 238/340 点、zh_CN h23/en_US h12 locale、Light/Dark、fresh/stale，共 16 个布局尺寸组合；测试通过不等于已经证明所有时间文本无截断、VoiceOver 朗读正确或实机颜色完全一致。

8 项 skipped：2 个 Contract B 外部样本/配置 gate，4 个真实 Android 生命周期/External/app-exit gate，2 个 Native Xtream 公网/renderer gate。未计入 passed；不为减少 skipped 而启用可能干扰真实验收运行时的测试。

Debug 使用命令行临时隔离 bundle ID 和 ad-hoc 签名，正式工程 bundle ID 未改。第一次测试申请被权限审查按此前只读要求拒绝；依据本轮最新明确授权复核获准后才执行，没有绕过拒绝。Packaging 测试首轮 1 项失败是 `/var` 与 `/private/var` canonical path 预期差异，修正测试为 resolved path 后 14 项全部通过。

既有 warning：Swift 6 并发/Sendable、WebKit、OpenGL/菜单 API 弃用、部分 await/try/类型推断，以及构建脚本未声明输出。APK 构建另出现 Kotlin metadata 2.2.0/2.0.0 不兼容诊断，但 Gradle assembleRelease 返回成功；未更改依赖来掩盖这些诊断。

没有重新请求真实外部 XMLTV、Pluto、联通或 Native Provider；没有运行真实播放首帧、快速换台、滚动 FPS、Mac 睡眠恢复或 VoiceOver E2E。它们属于下方人工验收。

日志：

- `/private/tmp/okvideomac-progress-core-focused.log`
- `/private/tmp/okvideomac-progress-core-full.log`
- `/private/tmp/okvideomac-progress-app-focused.log`
- `/private/tmp/okvideomac-progress-app-full.log`
- `/private/tmp/okvideomac-progress-full.xcresult`
- `/private/tmp/okvideomac-progress-packaging-tests.log`
- `/private/tmp/okvideomac-progress-acceptance-package.log`

## E. Acceptance

已完成 snapshot → APK build → arm64 clean Release → bundle assembly → 本地签名 → SBOM/敏感扫描 → ZIP/DMG → 挂载及最终验证。`package-local-acceptance.sh` 调用快照内 `package-app.sh` 成功退出（exit 0）。可交付的是本次已验证 Release，不是 Debug 或之前的 Fzrn0M 候选。

| 验收门禁 | 本轮结果 |
| --- | --- |
| arm64 clean Release | BUILD SUCCEEDED；0.6.1 / Build 101 |
| Bundle verification | staging、ZIP 解包、最终独立 App 均通过 |
| Mach-O / signing | 29 个 Mach-O 对象；local ad-hoc signing 验证通过 |
| Hardened Runtime | 主 App / Relauncher 等应有签名 flag 通过脚本校验 |
| SBOM | macOS 29 components；Android 172 components / 170 locked Maven modules；一致性验证通过 |
| Sensitive scan | App 扫描 138 文件、最终 SourceRelease 扫描 15 文件，均 CLEAN / 0 findings；未降低 forbidden-literal 门禁 |
| Source / binary provenance | 源码归档 hash、内嵌 source index、ZIP/DMG 对应关系通过；构建后 436 个输入与工作树逐文件一致 |
| Android Bridge | 从当前快照新构建 APK；签名 pin、打包与 DMG 内 APK 一致性通过 |
| Finder metadata / xattr | 复用临时 staging 清理及严格签名验证，未在用户同步目录重组 App |
| DMG mount | 通过；挂载内容/版本、source index、APK、App 严格签名复验通过；验证后卸载 |
| Notarized / Stapled | NO / NO |
| Gatekeeper assessment | NOT TESTED：ad-hoc 本地包不具备公证前提，不当作通过 |
| Installed / Launched / Public release | NO / NO / NO |

产物路径：

- App：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Artifacts/OKVideoMac.app`
- DMG：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Artifacts/OKVideoMac-0.6.1.dmg`
- ZIP：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Artifacts/OKVideoMac-0.6.1-macOS-arm64.zip`
- Source archive：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Artifacts/SourceRelease/OKVideoMac-0.6.1-build101-source.tar.gz`
- 公共形式源码清单：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Source/LOCAL_ACCEPTANCE_SNAPSHOT.json`
- 私有 provenance：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Source-PRIVATE-PROVENANCE.json`
- 完整 source/binary/SBOM 索引：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Artifacts/SourceRelease/`
- App 逐文件内容/权限/symlink 清单：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Artifacts/App-FILES.sha256.json`

SHA-256：

| 对象 | SHA-256 |
| --- | --- |
| App 文件清单（目录本身不能直接 shasum） | `aa3f7a40bea6cba21a9ccc01df8ccc34c8a6751f1e891939797380a8dde7ec9a` |
| App 主可执行文件 | `f939b79b726d7b3bc22c2743fcae60a1d4f3ff4931c3f30482bb9b3c7852608c` |
| DMG | `9f6e1e3302c322a93d84ab3ff9ad70eb3ec85248d927662b1d8dd235c7cd40ef` |
| Source archive | `daebb7a1867513cdf6d33228747b34a4dcc1553569be9fa35c77b4099f03e9b2` |
| ZIP | `6baecc8b58d07e89b09df2b3a747b96fecfcb3a0e9450339699856305eef172e` |

产物位于本机临时目录，可能被系统清理；需要长期保留时可手工保存已验证的 DMG/ZIP 和配套源码材料。未自动安装、启动或替换现有 App。

新快照：`/private/tmp/OKVideoMac-Acceptance.vCA8IE/Source`，436 个构建/配套源码输入。

source inventory SHA-256：`823d573b5f49ce3beeb72e8c56d17b20f963de1b5d1e15e6f9fdb02772f5a3ae`。

快照记录 branch、baselineHEAD、version/build、时间、纳入的 tracked modifications/untracked source 和逐文件 SHA-256。明确 gitCommitBound=false、acceptanceOnly=true、publicReleaseEligible=false，不冒充 commit-bound 源码。

为了满足本次验收要求，打包阶段单独修改 `Tools/SourceAudit/local_acceptance.py`、对应测试、`Scripts/package-app.sh` 及 `Docs/LOCAL_ACCEPTANCE_PACKAGING.md`：增加分支身份与捕获中分支漂移检查，排除不参与构建的 Docs/DemoSource，复用原 DMG 创建/挂载/验证流程。未修改正式版本、签名模式、APK 验证逻辑或敏感扫描限制。

仓库/worktree 绝对路径位于 `Source-PRIVATE-PROVENANCE.json`（0600），通过 snapshot manifest SHA-256 与源码清单绑定，保存在验收目录旁、不嵌入 App/DMG/源码归档。这样同时满足本地追溯和产物禁止泄露本机绝对路径的要求。

## F. 人工验收

仅在 E 节所有验收门禁成功后使用新候选；旧验收 App 不被自动替换。

1. 手工退出旧 App，打开新候选。确认仍为 0.6.1 / Build 101。
2. Live 检查时间—原生进度—时间同行；缩放窗口，查看中英、12/24 小时、Light/Dark、Accent 和 stale；确认两端时间完整。
3. History 查看零、中间、完成进度、多记录同屏及窗口缩放；duration 未知时不显示横条；无百分比徽章。
4. 用 VoiceOver 检查节目/观看进度、百分比、History 行 Button 是否重复朗读；进度应为只读，不出现 seek 行为。
5. 复验 EPG 外部/内嵌/自定义/禁用及三种 temporal 状态；保持原线路播放与快速换台。昨日 XMLTV 仍不会被伪造成今天节目。
6. 随机播放确认无回归；Player timeline 视觉不是本轮修改内容。

不自动安装、不覆盖 Desktop 或 Applications、不自动启动 App、不修改联通源、EPG URL、Xtream、Keychain。不 notarize、staple、commit、push、tag 或发布。
