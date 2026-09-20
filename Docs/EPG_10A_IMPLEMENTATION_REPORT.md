# EPG 10A 实施与验收记录

日期：2026-09-20。冻结方案见 `EPG_10A_REVISED_IMPLEMENTATION_PLAN.md`。

## 当前阶段

10A-A 至 10A-E 已完成并通过；下一步为 10A-F Release 性能与来源验收。C 全程没有读取
Repository，也没有增加生产入口；生产数据接线从 D 开始。

## A：基线、分支、合同与测量协议

- 开工前分支为 `codex/epg-9c-import`，旧 HEAD 为
  `14dd3a584f49bdb67a5b7edd25c9980f77f480e2`；完整 9C.4 当时仍位于 dirty tree，旧 HEAD 本身不是
  可恢复的 9C.4。
- 先用生产 local-acceptance 冻结器重新抓取 600 个产品输入；首次结果
  `a24146eacae003e5d09161489010084893d84159cef927f237d9a3190beaa3c0` 与 0.7.0 已验证 Release
  源码包完全一致，证明 10A 开工前产品输入没有漂移。
- 审计待提交清单时发现两个 Swift 源文件和一份探针文档仅在文件尾多一个空行。规范化这三处后，重新
  冻结并实际验证恢复，600 个输入的新清单 SHA-256 为
  `f8d9d2f0100136a5b05cef74b9f871bf6d9aabaaf217716ceeff1883f9533b8b`。变化只有空白，不改变产品行为。
- 将 241 个源码、测试、工具和必要报告提交为本地 9C.4 基线：
  `c9ab082904da9da9f1857c6ceb8638519f53bb11`，提交信息
  `feat: freeze 0.7.0 EPG production baseline`。没有 push、Tag 或发布。
- 408 MiB `Docs/LocalRecoveryEvidence`、171 MiB DemoSource v0.6.1 媒体和 2.4 GiB 被忽略的 EPG
  测量产物没有进入提交；它们保留在本机。10A 方案也没有混入 9C.4 基线提交。
- 从上述提交创建并切换到 `codex/epg-10a-guide`，分支起点验证一致。
- 既有验收基线保持：OKVideoKit 956 项执行，其中 20 项跳过，0 失败；macOS App 895 项执行，其中
  8 项跳过，0 失败，另有一项真实 ADB 集成测试明确排除。
- 已冻结 desired/runnable/running 三层调度、两个 12 小时切片、XMLTV coherence、Xtream per-row
  token、一次换代重试、状态组合、节目记录身份、分页 64/行 256/全局 6144、8 MiB 确定性 DTO
  计费和在途预留。
- 已冻结 F 阶段测量口径和拟定门槛：Store 正常 Window P95 10 ms、单次严重回退 50 ms、全部可见行
  首屏 P95 500 ms、Guide RSS 增量 32 MiB、60 Hz 帧间隔 P95 25 ms、Guide 主线程超过 100 ms 停顿 0。

A 阶段验证：两个冻结快照均通过逐文件哈希恢复验证；分支和基线提交身份核验通过；暂存清单未包含
大型本地证据、Demo 媒体或 10A 文件；`git diff --check` 通过。

结论：PASS，可进入 10A-B。

## B：有限需求模型、协调器和查询投影

- 新增 `EPGGuideDemand`，一次需求只允许 1～48 个唯一频道、1～2 个相邻且单段不超过 12 小时的
  时间切片，并携带 source、revision、capability 和唯一 `demandRevision`。
- 新增纯 `EPGGuideWorkCoordinator`。它保留全部 desired rows，同时把 runnable 限为 8、running
  限为 4；优先级依次为焦点、可见且正在播放、可见、预取，并保证所有行的第一页先于某一行继续翻页。
- XMLTV 查询按 2,162,688 bytes、Xtream 查询按 81,920 bytes 预留在途预算。正在运行的预留暂时
  占满 8 MiB 时，等待行留在有界队列中；只有单个任务在没有其他 reservation 时仍不能进入，才记为
  `.byteBudget`，避免把暂时背压误判为永久截断。
- 冻结每页 64、每行 256、全局 6144 和 8 MiB 确定性 DTO 计费；达到任一上限后进入带原因的终态，
  不重试、不延迟积压。旧 snapshot 只有在阻塞可见数据进入预算时才释放。
- `EPGWindowPage` 增加 generation 内稳定的 `EPGWindowProgramme` 记录身份，保留原 programmes
  投影兼容既有调用者。XMLTV 使用数据库 programme ordinal；Xtream 使用短缓存数组 ordinal。
- Repository/Service 将 active generation 变化明确分类为 `snapshotChanged`，将查询时间预算耗尽明确
  分类为 `queryBudgetExceeded`，不再折叠成普通无效请求。
- 新增 `EPGGuideCoherenceGate`：XMLTV 同一需求的全部结果必须拥有完全相同 token；第一次换代冲突
  允许整批重建一次，第二次冲突终止。Xtream 明确采用 per-row token，不伪造全局 generation。
- 新增 `loadXtreamWindow`，与 Now/Next 共用同一个 channel-scoped flight 和 5 分钟短缓存。并发请求
  只进行一次 fetch，Guide 投影不会另建第二份 payload 或第二个缓存版本。

B 阶段定向验收：`EPGGuideCoreTests`、`EPGProductionRepositoryTests`、
`EPGProductionServiceTests` 共 17 项执行，0 跳过，0 失败。覆盖 48 行最终可达、队列与并发峰值、分页
公平性、旧 snapshot 释放、三类截断、重复记录拒绝、XMLTV 单次重试、Xtream per-row token、
Now/Next 与 Guide 并发 flight 合并、稳定 ordinal 和缓存版本复用。

B 阶段全量验收：OKVideoKit 966 项执行，其中 20 项跳过，0 失败；`git diff --check` 通过。

结论：PASS，可进入 10A-C。

## C：纯 fixture AppKit 网格

- 新增 `LiveGuideGridView`，节目块由 `NSCollectionView` 和自定义 layout 虚拟化；layout 只为当前
  可见矩形生成 attributes，不为屏幕外节目创建 view。
- 顶部时间轴和左侧频道列是独立轻量 AppKit view，单向读取同一个内容 clip view 的滚动坐标。
  横向滚动只改变时间轴绘制偏移，纵向滚动只改变频道列绘制偏移，没有互相回写 scroll position 的
  反馈循环。
- 网格使用真实 `Date` 时间差定位节目和当前时间线；民用时钟只用于标签。DST 秋季回拨时，重复的
  `01:00`/`01:30` 自动附带各自 GMT offset，因此位置与文案都不含歧义。
- 节目 item 提供频道、节目名和时间范围的 VoiceOver 内容；方向键以相邻节目或相邻频道的最近时间
  中点移动焦点，Return/Space 使用同一 activation 路径。配色全部使用动态 AppKit system colors。
- fixture 模型继续执行 48 行、256/行、6144 全局和稳定 programme identity 限制；时间标签缓存硬限
  64。调试指标分别记录当前可见 view、跨滚动实际出现过的 view、layout attribute 和标签缓存数量。
- 在 1,152 个节目 fixture 上连续跨四段双轴滚动，固定标题 frame 保持不变，实际 item 实例和每帧
  layout attributes 均显著小于总节目数；resize 后固定区和内容区重新布局正确。暗色外观和 2× layer
  scale 使用同一几何与复用路径。

C 阶段定向验收：`LiveGuideGridTests` 4 项执行，0 跳过，0 失败。macOS App Debug 完整构建成功。

C 阶段全量验收：macOS App 899 项执行，其中 8 项跳过，0 失败；仅额外排除既有的真实 Android
退出集成测试 `testAndroidRealApplicationTerminationIsBoundedAndClean`。`git diff --check` 通过。

结论：PASS，可进入 10A-D。

## D：XMLTV 生产查询、状态和 UI 接线

- 新增 `EPGGuideXMLTVLoader`，通过 9C.4 的生产 Repository 执行窗口分页查询；最多 4 个查询同时
  运行，按 Coordinator 的 desired/runnable/running 合同补充后续行，两个相邻切片按稳定 programme
  identity 去重。
- XMLTV 全需求只接受同一个 service incarnation、resource identity、source epoch、generation 和
  demand revision。查询中发生 generation 变化时只允许整批重建一次；交付前再次读取 active status，
  旧 generation 的迟到结果不能发布。
- 精确频道 ID、规范化名称、歧义、未匹配和查询失败保持不同状态。完整且合法的 0 programme active
  generation 会发布为真正的空表；损坏刷新会保留并继续查询上一份合法 active generation。
- 新增 `LiveGuideState` 生命周期状态机。顶层状态为 inactive/loading/content/empty/unsupported/failed，
  content 内单独表达 fresh/stale 和 idle/loading/backoff，避免布尔组合爆炸。发布时只比较一个统一交付
  identity；换源、换 revision、换 demand 后的旧结果全部丢弃，同源刷新失败则保留旧 snapshot 并标 stale。
- `AppState` 将 Guide 窗口查询接到既有 XMLTV refresh owner。100 ms debounce、最多 48 行和 1～2 个
  12 小时切片只取消展示需求，不取消几十 MiB 的共享刷新；sleep 会暂停查询并保留 stale 内容，wake
  从同一 Repository 重建需求，shutdown 取消并退出。
- Live 页面新增频道/Guide 切换、前后 12 小时、日期跳转和 Now；搜索、分组、收藏先于 48 行上限生效。
  网格可见范围驱动有限预取，选择节目只显示轻量详情。节目、频道双击或 Return 最终都调用既有直播
  播放入口，按钮文案固定为“播放频道”，EPG 查询和刷新不进入播放等待链。
- AppKit 网格补充 production representable、节目与频道 activation 和可见行回调，继续保持滚动位置只
  在局部 AppKit/Live 会话中，不进入全局 `AppState` 高频发布。
- 修复测试 loopback server 的无界 `Process.waitUntilExit()`：先 TERM，有界等待 2 秒，再在必要时
  KILL 并有界等待。原先偶发挂住的 supersede/shared-waiter 用例恢复正常执行，没有被永久排除。

D 阶段定向验收：`EPGGuideXMLTVLoaderTests` 3 项、`LiveGuidePresentationStateTests` 与
`LiveGuideGridTests` 8 项，均为 0 跳过、0 失败；macOS App Debug 构建成功。

D 阶段全量验收：OKVideoKit **969 项执行，其中 20 项跳过，0 失败**，不排除任何用例；macOS App
**903 项执行，其中 8 项跳过，0 失败**，仅额外排除必须连接真实 Android 设备的既有集成测试
`testAndroidRealApplicationTerminationIsBoundedAndClean`。`git diff --check` 通过。

结论：PASS，可进入 10A-E。

## E：Xtream 短表、故障与竞态闭环

- 新增 `EPGGuideXtreamLoader`，仍使用 B 阶段同一 `EPGGuideWorkCoordinator`：保存全部 desired rows，
  runnable 不超过 8，实际 fetch/query 不超过 4；Now/Next 和 Guide 通过 Repository 的 channel-scoped
  flight 与 5 分钟缓存合并，不创建第二套 Xtream 请求或缓存。
- Xtream snapshot 固定为 `.perRowToken`。每行 token 绑定 service incarnation、配置修订、频道资源、
  cache version 和 demand revision；两片中同一行 token 改变时废弃候选并最多整批重建一次，不伪造
  跨频道 generation。
- 缺少稳定 locator、服务端明确 unsupported、以及短表已有节目但目标时间窗在覆盖外，分别形成明确的
  unsupported 行；只有服务端成功返回完整 0 programme payload 才是 empty。跨两个 12 小时片的同一
  短表记录按 cache version + ordinal 去重。
- AppState 按 capability 选择 XMLTV 或 Xtream adapter。运行时凭据只留在 `XtreamEPGAdapter.fetch`
  闭包，Snapshot/Context 只携带 credential-free provider、server 和 stream identity；配置记录、provider
  ID 与 locator 必须一致才准入。
- `LiveGuideState` 同时验证 XMLTV 全局 token 和 Xtream per-row token。用户切源、切日期、快速滚动、
  A→B→A、配置修订或 service incarnation 改变后，旧交付均不能发布；同源刷新仅按同一 service 与
  capability 保留旧图，不错误要求旧图拥有新的 demand revision。
- 需求合并采用 100 ms quiet interval 和从首个连续需求起最多 250 ms 的硬等待。像素级连续滚动可以
  取消旧展示查询，但不能无限推迟实际加载；资源级 XMLTV 刷新仍不随 Guide 滚动取消。
- sleep 先撤销交付资格、取消有限查询并保留同源 stale 图，再有界 pause Repository；wake 在 resume
  后重建当前需求；shutdown 撤销输入并有界 close。Repository invalidation 会取消旧 Xtream flight，
  迟到结果不能填入替代缓存。
- UI 明示 Xtream 只提供近期节目，短覆盖之外不显示“没有节目”的虚假结论。所有 unsupported/failed
  页面继续保留有限频道列表和“播放频道”。Guide activation 只调用既有 `playLive`/
  `playImportedLive`；这两个入口直接进入播放 coordinator，不读取 Guide snapshot、等待 Repository
  或等待 EPG 网络请求。

E 阶段定向验收：Xtream Loader 3 项；预算、查询队列满/取消/换代、Repository stale/invalidation、
pause/resume/close 等组合门禁 32 项；`LiveGuidePresentationStateTests` 7 项，全部 0 跳过、0 失败。
其中覆盖 20 行全部进入终态且 fetch 峰值不超过 4、取消一个消费者不取消共享 flight、A→B→A、
service 重启隔离、全 unsupported、旧图刷新保留和 250 ms 最大等待。

E 阶段全量验收：OKVideoKit **972 项执行，其中 20 项跳过，0 失败**；macOS App **906 项执行，
其中 8 项跳过，0 失败**，仅额外排除必须连接真实 Android 设备的既有集成测试
`testAndroidRealApplicationTerminationIsBoundedAndClean`。`git diff --check` 通过。

结论：PASS，可进入 10A-F。
