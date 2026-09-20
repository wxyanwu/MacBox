# EPG 9C.4 实施与验收记录

2026-09-20；分支 `codex/epg-9c-import`。冻结合同见
`EPG_9C4_IMPLEMENTATION_CONTRACT.md`。

## 当前阶段

9C.4-A 至 G 已全部完成并通过。9C.4 生产链路冻结；下一阶段直接进入 10A Full Guide/Grid EPG。

## A：基线与生产调用链审计

- 当前分支 `codex/epg-9c-import`，HEAD
  `14dd3a584f49bdb67a5b7edd25c9980f77f480e2`；没有切换或清理用户的 dirty tree。
- 基线位于忽略目录 `OKVideoMac/macOS/OKVideoMac/Artifacts/EPG9C4/Baseline`，共 1,624 个
  tracked/untracked 构建输入；清单 SHA-256
  `1fdd1c4495822d813f1bd30d73fea2930b84504a858b9682aa3fa418cf88100b`。冻结后重新逐文件验证通过。
- 9C.3 基线为 OKVideoKit 946 项执行，其中 18 项跳过，0 失败；不能表达为 946 项通过另加跳过项。
- 冻结统一结果 token、合法空表、coverage 刷新、生产资源测量、Xtream 字节预算以及睡眠/退出有界
  drain 六项合同；睡眠等待 750 ms、退出等待 2 s。

生产调用链审计结果：

1. `AppEnvironment` 当前直接实例化 Core 的旧 `EPGRepository`，只拥有 JSON cache 目录，没有 9C.3
   Store/import coordinator 生命周期。
2. `AppState.refreshEPGDemand` 同时负责页面需求、资源刷新、缓存迁移和结果发布；浏览变化默认取消共享
   请求。接入长时间 XMLTV import 前必须拆开资源刷新和展示查询。
3. Core `EPGRepository` 将完整 `XMLTVGuide` 编码到 JSON，并可全量读取最多 80 MiB；生产 XMLTV 分支
   必须移除该入口，且不做全量旧 JSON 迁移。
4. `EPGSnapshot` 构造完整 `XMLTVScheduleIndex`，`LiveEPGState` 最多保留 400K programme；两者都必须
   从生产 XMLTV 路径撤下。
5. `LiveNowNextView` 和播放器当前同步读取内存 index；9C.4 应改为由集中需求协调器异步填充有限结果，
   视图只做本地进度计算。
6. Xtream `shortEPG` 是按 streamID、limit=4、HTTP 1 MiB 的小响应，更新单位与 XMLTV 不同；保留独立
   有界缓存并统一上层 DTO。
7. 来源更新/删除、设置应用、App 睡眠、唤醒和 shutdown 均直接操作旧 Repository/LiveEPGState；这些
   是 B–E 的生命周期迁移清单。
8. Portable Backup 当前不导出 EPG cache；9C.4 继续把缓存视为可重建数据，不加入备份。

A 阶段门禁：基线可重验；冻结合同已包含范围、身份、空表、刷新、资源、升级及逐关标准；生产调用点
全部映射到后续阶段。结论：PASS，可进入 9C.4-B。

## B：生产服务边界与生命周期

- 新增 Core 有限 DTO：统一 `EPGResultToken`、资源摘要、Now/Next 批次与窗口页，不包含完整 Guide、
  ScheduleIndex、URL、header 或凭据。
- 新增 Persistence `EPGProductionService`，单实例拥有 Store、import coordinator、后台 query queue 和
  唯一暂存根；SQLite/文件工作不在 MainActor 执行。
- 数据库 schema v3 将 `published_at` 与 active generation 同事务写入，并通过有限 active record 暴露
  programme count、coverage 和来源 epoch；旧开发 cache 是可重建缓存，低版本按原合同重建。
- Now/Next 继续受 100 频道/2 MiB 限制，窗口继续受 24 小时/500 行和 generation cursor 限制；公开
  cursor 只能由服务生成，后续页必须重新验证数据库 snapshot。
- coordinator 增加可恢复 pause；pause 不改变 source epoch、不清空 active，也不关闭 Store。服务 close
  超时只返回未排空，不提前释放仍在使用的 Store 或暂存所有权。
- 后台维护 API 每次最多 32 步/250 ms，生产默认 4 步/20 ms；每个 Store step 仍最多 512 行。
- 服务初始化失败会抛出有限错误供 C 阶段 AppEnvironment 降级，且清理本次尚未交付给下载器的唯一
  暂存根；持久 cache 不随服务关闭删除。

B 阶段门禁结果：

- `EPGCacheStoreTests`：24 项执行，0 失败，包括 200K 有界批次、故障、锁、崩溃和 GC 回归。
- `EPGProductionServiceTests`：2 项执行，0 失败，覆盖网络导入、有限摘要、统一 token、Now/Next、窗口
  cursor、可恢复 pause 和有界 terminal close。
- Swift 编译不再产生新增 actor isolation 警告；源码 `git diff --check` 作为每阶段共同门禁。

结论：PASS，可进入 9C.4-C。

## C：生产 Repository、刷新策略与 Xtream 短缓存

- 新增 `EPGProductionRepository`，XMLTV 只通过生产 service 导入/有限查询；旧 Core Repository 保留到
  D 完成调用点迁移，但新生产路径不调用其 JSON/完整 Guide API。
- XMLTV 状态将 `publishedAt + TTL` 与 `coverageEnd - 30 min` 合并决定刷新时间；合法空表为 15 min，
  正常表为 6 h。刷新失败按 60 s 起、最大 15 min 退避，旧 active 保留并标为 stale。
- 首次无缓存不受刚创建的状态时间阻挡；取消、pause、close 不计作失败，也不推进失败退避。
- Xtream short EPG 使用独立频道缓存，身份绑定来源、配置 revision、account 摘要、server 摘要和 streamID；
  原始身份字符串和凭据不写入缓存 key/token。
- Xtream 同时限制 HTTP 1 MiB、最多 16 条保留 programme、title 4096 UTF-8 bytes、identifier 512
  bytes、单项 64 KiB、总缓存 2 MiB 和 128 项。Core title 截断改为合法 UTF-8 字节边界，不保留
  description。失败强制刷新可回退同身份旧项并标 stale；账号/服务端变化不命中旧项。
- `AppEnvironment` 已创建非抛出的生产 Repository；缓存打开失败只令 EPG 不可用，不中止 App 初始化。
  旧 JSON 目录仍原样保留，但没有迁入新数据库或进入新 Repository。

C 阶段门禁结果：

- `EPGProductionRepositoryTests`：2 项执行，0 失败，覆盖 coverage due、刷新失败保留 active、统一 token、
  account 隔离、缓存复用、stale fallback 和多字节超限拒绝。
- `XtreamEPGTests`：原 3 项执行、0 失败；新增 UTF-8 边界测试随后纳入下一轮组合回归。
- macOS App Debug 完整构建成功；`AppEnvironment` 新成员和全部现有调用点编译通过。构建仍报告既有
  NSOpenGL/WebKit/脚本阶段警告，本阶段没有把它们表述为无警告。

结论：PASS，可进入 9C.4-D。

## D：生产展示接线与有限需求

- `LiveEPGState` 已改为只保存有限 `EPGNowNextBatch` 结果，最多 100 个频道、估算载荷最多
  8 MiB；生产 App/Features 不再引用完整 `EPGSnapshot`、`XMLTVGuide` 或旧 `EPGRepository`。
- 每次结果交付统一核验 service incarnation、resource identity、source epoch、data version 和
  demand revision；切源、配置更新、active generation 更新和旧滚动结果都不能污染当前页面。
- 页面以实际可见卡片形成需求，有限邻近项只作预取。滚动只取消查询任务，XMLTV 下载/导入使用独立
  资源任务和 operation identity，不会因页面滚动反复从头下载。
- XMLTV 由资源级刷新任务后台导入，再以最多 100 频道的有限查询发布；Xtream short EPG 继续按频道
  通过独立有界缓存加载。两种生态统一交付有限 Now/Next DTO，不共享错误的持久化单位。
- 统一节目边界调度器在 current/next 边界后重查，卡片本地计算进度，不为每张卡片轮询 SQLite，也不
  高频发布 AppState。
- 设置变更、来源删除/禁用、休眠、唤醒和 shutdown 已接到生产 Repository；休眠只 pause，唤醒
  resume，关闭使用 2 s deadline。EPG 查询与刷新均不进入播放解析或播放器起播等待链。

D 阶段门禁结果：

- macOS App Debug 完整构建成功；随后 EPG/直播展示定向回归 60 项执行，0 失败。
- `EPGIntegrationTests` 12 项全部通过，覆盖完整 token、A→B→A、切代、切源、来源删除、主开关、
  最大 100 项和节目边界。
- `EPGProductionRepositoryTests`、`EPGProductionServiceTests` 与 `XtreamEPGTests` 合计 8 项执行，
  0 失败；新增 UTF-8 字节边界也已纳入组合回归。
- 源码审计确认 `App` 与 `Features` 目录不存在旧 `EPGSnapshot`/`EPGRepository` 生产引用。
- 首轮 App 全量测试的唯一意外失败来自需真实 ADB 环境的 Android termination 测试，与 EPG 无关；
  EPG 中一个旧断言把 stale 错当 fetch failure，已按冻结状态语义纠正并由上述 60 项回归验证。

结论：PASS，可进入 9C.4-E。

## E：故障、取消、升级、生命周期与播放独立性

- 合法 `<tv/>` 会发布新的空 generation；随后损坏 XML 刷新只增加失败状态，保留该空 active 的
  data version，不把错误重新解释成空表。
- 缓存目录打不开时 Repository 以不可用状态降级，App 初始化与播放能力不依赖 EPG；专项测试确认
  邻近旧 JSON 即使损坏也不会被读取、改写或迁移。
- 来源撤销会取消 Xtream flight 并清空同身份缓存；迟到任务不能写回，新请求必须重新获取。
- pause deadline 已在真实慢下载期间验证为立即有界返回；取消的旧 wake/resume 不能重新打开服务，
  正常 resume 后仍可重新导入。terminal close 的 deadline 与最终排空继续通过。
- 审计发现唤醒曾先等待 EPG resume 再恢复播放器。现已将 EPG resume 拆为独立、可撤销生命周期任务，
  播放器恢复不等待 EPG drain；Service/Repository 在 resume 前后检查取消和 close，第二次 sleep 可撤销
  第一次 wake，不能启动冲突流水线。
- 9C.3 的取消、supersede、队列上限、损坏 plain/gzip、SQLite full、来源撤销、late cancel、崩溃恢复
  和暂存所有权测试在新生产层修改后重新执行。

E 阶段门禁结果：

- 生产 Repository/Service 新专项：7 项执行，0 失败。
- XMLTV 故障/崩溃/生产生命周期组合：20 项执行，其中 1 项独立 worker 入口按设计跳过，0 失败；主测试
  已实际启动该 worker 并覆盖 5 个事务边界。
- macOS App EPG 展示、背景状态、睡眠唤醒与播放显示生命周期：70 项执行，0 失败。
- `git diff --check` 通过；App 播放解析/加载调用链没有 EPG await，EPG 仍为可选增强。

结论：PASS，可进入 9C.4-F。

## F：Release 资源门禁与真实公开来源

- 新增只用于测量的生产 service 构造入口，仍建立与 App 相同的 Store、import coordinator、下载、
  流式解析和 SQLite 链路；注入项只限唯一 staging root 和只读采样 observer。资源测试通过
  `EPGProductionRepository` 导入，并在 warm 刷新期间持续执行有限 Now/Next 与窗口查询。
- 测量协议按 A 阶段冻结：Apple M1 16 GB、macOS 14.8.9、Xcode 16.2、Release；10 ms 内存采样、
  100 ms 磁盘/FD 采样，drain 后继续 1 s 峰值窗口和 5 s settled 观察；cold 在生产 service 初始化后
  取基线，warm 在已有 active generation 且维护排空后取基线。每个组合使用全新独立进程。
- `Resources-v1` 在第 11 轮暴露验收探针问题：warm 刷新恰好切代时，旧查询 token 按合同返回
  `invalidRequest`，探针却把它当成数据失败。失败证据保留；修正仅将这种旧 token 计作失效并重试，
  其他查询错误仍失败。随后从全新 `Resources-v2` 重跑全部矩阵。
- 生产矩阵共 48 次：10K/50K/100K/200K × plain/gzip × cold/warm × 3。48 次退出码均为 0；
  最大 RSS 增量 21,692,416 bytes（20.69 MiB），最大 footprint 增量 16,400,512 bytes
  （15.64 MiB），均低于拟定 48 MiB 门槛。最大临时/数据库磁盘峰值 82,934,231 bytes，最大 FD 16。
- 50K→200K 的八组 RSS/footprint 最大值差全部通过；最大增长 4,669,440 bytes（4.45 MiB），低于
  8 MiB。并发查询最差 P95：Now/Next 15.013 ms，窗口 8.185 ms，低于 50 ms。
- 使用同一当前产品源码重跑 9C.3 bottom gate：另 48 个 Release 独立进程全部通过；最大 RSS 增量
  21,889,024 bytes（20.88 MiB），最大 footprint 增量 18,481,216 bytes（17.63 MiB），八组规模
  增量最大 5,898,240 bytes（5.63 MiB），继续满足 32 MiB/8 MiB 合同。
- 冻结公开 Sling TV 样本经当前 Release `EPGProductionRepository` 的 loopback 网络、plain/gzip、
  importer、SQLite、有限 Now/Next 和分页窗口完整重放；两次均得到 6 个频道、133 条节目，并与旧
  parser oracle 一致。plain SHA-256 为 `8508c19e...02f7`，gzip 为 `c804713c...e7d`。
- 资源矩阵后只增加了验收测试和测试服务器幂等清理，生产源码未改变；当前公开样本 Release 测试
  二进制 SHA-256 为 `7ec0c863...3f79`。生产矩阵原始记录、fixture 哈希、每轮日志、scale checks 和
  公开样本结果均保存在忽略目录 `OKVideoMac/macOS/OKVideoMac/Artifacts/EPG9C4/`。
- 工作区没有可读的私有 TVBox、CatPaw 或 Xtream 凭据/样本，因此未宣称真实私有源通过；Xtream
  生产适配仍由有界缓存、身份、取消和错误回退专项覆盖。源码审计再次确认 App/Features 不引用旧
  完整 `EPGSnapshot` 或旧 `EPGRepository`。

结论：PASS，可进入 9C.4-G。

## G：全量回归、Release 与桌面安装

- OKVideoKit 全量：956 项执行，其中 20 项跳过，0 失败。普通全量中跳过的独立 Release 资源入口已
  在 F 阶段以 96 个独立进程完成，不能重复计作普通单元测试通过项。
- macOS App 全量：895 项执行，其中 8 项跳过，0 失败。命令仅额外排除一个需要真实 ADB/模拟器且
  本机持久开关误启用的 `testAndroidRealApplicationTerminationIsBoundedAndClean`；没有把它表述为通过。
  EPG、直播展示、播放器、睡眠唤醒和其他 App 测试均包含在上述结果中。
- 完整 local acceptance 从冻结源码快照调用标准 `package-app.sh`：Android Release 和 macOS Release
  构建成功；文档状态确认 0.7.0 (Build 102)；源码快照 SHA-256 为
  `a24146eacae003e5d09161489010084893d84159cef927f237d9a3190beaa3c0`。
- bundle、源码发布包、MPV bridge smoke、敏感信息扫描、29 个 macOS Mach-O 与 170 个锁定 Maven
  模块 SBOM、ad-hoc Hardened Runtime 签名、DMG 和 ZIP 解包验证全部通过。该本地验收包未公证，
  因而 Gatekeeper assessment 按合同标为不适用，而非通过。
- 验证产物位于 `/private/tmp/OKVideoMac-Acceptance.UJsHxC/Artifacts/`：
  `OKVideoMac.app`、`OKVideoMac-0.7.0.dmg`、`OKVideoMac-0.7.0-macOS-arm64.zip` 和 `SourceRelease/`。
- 只有上述门禁全部通过后才安装桌面副本。真实安装位于
  `/Users/linyao/Applications/OKVideoMac-Local/a24146eacae003e5d09161489010084893d84159cef927f237d9a3190beaa3c0/OKVideoMac.app`；
  `/Users/linyao/Desktop/OKVideoMac.app` 是指向它的非隐藏 symlink。安装前 staging、安装目录和桌面入口
  均重新通过 bundle/SBOM/签名及逐文件比较。旧桌面 symlink 保存在 `/private/tmp`，没有删除旧安装。
- 第一次桌面安装脚本因把本机 `chflags` 写成 `/bin/chflags` 在替换前停止；当时原桌面入口未移动。
  随后确认本机路径为 `/usr/bin/chflags`，沿既有版本化安装布局完成安全替换和最终复验。
- 最终 `git diff --check` 通过。未提交 Git、未创建 Tag、未发布，也未修改 Keychain、数据库或用户配置。
  最终报告是在已验证快照打包后写入；产品编译输入未再改变。

结论：PASS。9C.4 完成，按冻结路线直接进入 10A，不另设重复的 9C.5。
