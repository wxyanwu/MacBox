# EPG 9C.3 实施与验收记录

2026-09-20；分支 `codex/epg-9c-import`。冻结合同见 `EPG_9C3_IMPLEMENTATION_CONTRACT.md`。

## 当前阶段

**9C.3 A–G 全部通过，验证后的 Release 已安装，桌面入口已更新。**

此结论限于冻结的底层链路与所列实测覆盖；生产 Repository/App/UI 尚未切换，私有提供者样本未验证。

9C.3 连接网络下载、私有文件、plain/gzip 流式解析、SQLite 暂存、完整验证、原子发布和 9C.2 查询。生产 Repository/App/UI 的调用路径不在本阶段切换。

## 实现

- 发布资格复用 `EPGCacheImportHandle`，绑定 Store incarnation、资源、来源 epoch、request 与 generation。进入 writer 串行区后再次核验；`EPGImportControl` 的 stop 与最终提交仲裁，提交成功后不再因迟到取消把成功报告为失败。
- 新增 `EPGXMLTVImporter`，本地暂存文件和网络下载文件走相同入口。只有完整 XML、gzip 全部 member/CRC/物理 EOF 与 SQLite 校验均成功才 activate；错误路径显式 abandon 和有限 GC，不覆盖原错误。
- `EPGImportCoordinator` 单条活动流水线、最多四个待处理请求，每项最多八个合并订阅；普通同 key 合并，force/revision 替代先取消排空。Store 级租约还防止不同 coordinator 或本地入口并行写入。
- metadata sink 把频道的每个 display-name 作为事实分批交付，SQLite 负责去重；新 summary 不累计频道数组/节目频道 ID Set。节目和频道分别最多 512 条、1 MiB 一批，同步回调提供背压。
- 有用文本在累计时限制；无用文本不保存。显式取消传播到文件读、gzip、XML 回调、sink 和 SQLite validate progress handler。旧 collecting parser 保留既有行为并作为 oracle。
- 暂存目录持有独占 flock；崩溃恢复有扫描数量上限，只删除自有私有根内、无活动锁的标准 UUID 子目录及唯一 payload；不跟随符号链接，不递归清理未知内容。
- 完整合法零 programme 文档可以发布为空；出现 programme 元素但全部无效仍为错误。下载失败、损坏尾部、取消和发布资格失效不能替换同资源的旧合法 active。

## 逐阶段证据

| 阶段 | 门禁 | 状态 |
|---|---|---|
| A | 原 dirty tree 完整基线、9C.2 证据和正确分支 | PASS |
| B | 元数据流式化、字段限制、旧 parser oracle、背压与显式取消 | PASS |
| C | 本地 plain/gzip → SQLite → 查询、空表语义、坏尾部保留旧 active | PASS |
| D | 最终下载器回环、重定向/凭据剥离、队列/合并/supersede/close | PASS |
| E | 实际 SQLite FULL、复制 ENOSPC/取消、进程崩溃、恢复与资格竞态 | PASS |
| F | 48 次 Release 资源矩阵、连续生命周期、metadata 分布、公开源 oracle | PASS |
| G | 全量回归、Release 打包和验证后安装 | PASS |

B：组合回归 44 项执行、0 失败；补充后的 metadata 专项 5 项执行、0 失败。C：28 项执行、0 失败。D：7 项执行、0 失败。E 最终组合：77 项执行，其中 1 项为未提供 crash worker 环境时跳过，0 失败；父测试实际启动子进程执行 crash 边界。阶段之间有测试重叠，不能把这些数相加作为独立覆盖总数。

崩溃注入最初暴露了测试工具问题：`kill(getpid(), SIGKILL)` 返回后线程仍可能在信号真正送达前继续 COMMIT。现在发送信号后停在 `pause()`，父进程核对 crash marker 和退出信号；修正后 pre/post commit 原子性检查通过。初次失败日志保留，不伪装成首次全过。

## 资源协议与限制

Release / M1 / macOS 14.8.9，10K、50K、100K、200K 同逻辑内容 plain/gzip，cold/warm 各三次独立进程。cold 不代表清除了 OS 文件缓存。10 ms RSS/phys_footprint 采样，100 ms 磁盘/FD 采样和边界补采，包含 GC 和排空后一秒。全部实测、最大值和中位数留档。

每个进程导入后以有界 SQLite cursor 对每条 programme 计算逻辑 SHA256，与外部生成器 oracle 对比；100 频道 Now/Next、单频道 500 行窗口以及刷新期间查询分别计算 P95。测量窗口内不构造完整 `XMLTVGuide` 或节目数组。

Foundation 临时文件从进度和 pinned fd 的 fstat 计入，应用根内统计 staging、DB、WAL、SHM；逻辑文件大小不是磁盘分配块数。32 MiB 与 8 MiB 是指定平台/fixture 下的采样门禁，不能宣称是 Foundation 内部缓冲的数学硬上限。

## 真实样本边界

公开 XMLTV 样本来自 `jasonramg/iptv-epg` 的 Sling TV 元数据。直接下载入口遇到超时，改用 GitHub 文件接口取得完整原件，校验 Git blob SHA 后冻结；源原始 gzip 解压与 XML 完全相同。回放使用同一最终下载器与本地 HTTP fixture，完整节目字段、频道匹配与 Now/Next 与旧 parser oracle 比较。它证明已捕获字节的格式兼容，不能冒充真实端点全时可达性。

没有读取用户私有配置/数据库，也没有取得私有 Xtream、CatPaw 或 TVBox 提供者专属 XMLTV 样本；这些端点与生产生命周期接入仍须在 9C.4 取得授权样本后补测。三个生态的 JSON/short EPG 不是本阶段 XMLTV importer 的输入。

## 后续接入约束

9C.4 应消费本阶段成熟的 importer/query：将有限 DTO 提供给 Repository，生产 UI 不接完整 guide，不在 MainActor 做 SQL。生产缓存根及后台 GC 调度需单独设计；9C.3 的 importer 仍使用受限开发暂存根，`cleanupIncomplete` 是明确维护信号，调用方必须继续有限排空。不要把当前开发 SPI 直接改成无边界生产入口。

## F：48 次资源矩阵实测

RSS 与 footprint 均为相对 baseline 的峰值增量；表内为三次独立进程的 **最大值 / 中位数**，单位 MiB。所有原始测量和 fixture SHA256 另存验收证据。

| Programme | 格式 | 场景 | RSS 最大 / 中位 | footprint 最大 / 中位 |
|---:|---|---|---:|---:|
| 10,000 | plain | cold | 11.11 / 11.05 | 6.91 / 6.83 |
| 10,000 | plain | warm | 5.72 / 5.70 | 5.59 / 5.56 |
| 10,000 | gzip | cold | 9.16 / 9.02 | 4.94 / 4.75 |
| 10,000 | gzip | warm | 5.44 / 5.41 | 5.33 / 5.27 |
| 50,000 | plain | cold | 16.67 / 15.31 | 11.06 / 9.30 |
| 50,000 | plain | warm | 12.94 / 12.23 | 11.59 / 11.25 |
| 50,000 | gzip | cold | 10.80 / 10.59 | 6.58 / 6.34 |
| 50,000 | gzip | warm | 11.42 / 11.00 | 11.31 / 10.84 |
| 100,000 | plain | cold | 16.56 / 16.38 | 8.94 / 6.98 |
| 100,000 | plain | warm | 15.02 / 14.84 | 10.83 / 10.31 |
| 100,000 | gzip | cold | 11.41 / 11.34 | 7.19 / 7.14 |
| 100,000 | gzip | warm | 13.84 / 13.58 | 13.45 / 12.88 |
| 200,000 | plain | cold | 21.45 / 20.97 | 11.02 / 10.48 |
| 200,000 | plain | warm | 16.47 / 15.88 | 14.53 / 14.42 |
| 200,000 | gzip | cold | 12.98 / 12.86 | 8.88 / 8.58 |
| 200,000 | gzip | warm | 15.48 / 15.30 | 15.39 / 15.20 |

48/48 导入、逐条 programme digest、批次边界、内存及查询门禁全部通过。50K→200K 的八项最大值差比较全部通过，最大为 4.78 MiB（plain/cold RSS），低于 8 MiB。
普通 Now/Next、窗口查询的最差 P95 分别为 0.935 ms、1.057 ms；刷新期间分别为 1.446 ms、1.575 ms。磁盘采样最大 78.88 MiB，FD 最大 16。
200K 正向 plain 为 23,074,879 字节，gzip 为 737,886 字节；两者逻辑 oracle SHA256 相同。

## F：补充场景结果

12 轮（36 次导入尝试）成功/写入失败/取消全部通过，旧 active 在失败及取消后保持不变，各轮暂存文件清空。末轮相对第 3 轮 RSS 增量 -0.52 MiB、footprint 增量 2.78 MiB、磁盘增量 0.06 MiB、FD 增量 0。
20K 唯一频道 + 同一频道 20K 别名正确导入为 40K facts、20,001 唯一频道，空 programme 发布成功；额外 RSS/footprint 峰值分别为 0.48/0.08 MiB。
主动本地 stop 到失败清理返回最大 2.68 ms；慢网络请求的 cancel 到下载器 completion 及应用文件清理完成返回 0.70 ms，分开记录，没有把本地 parser 延迟冒充网络完成延迟。
公开源 6 个频道、133 条节目，原始 XML 和上游 gzip 两次独立完整链路均通过：全部节目字段/时间、全部声明频道 ID/显示名匹配与旧 oracle 一致，另校验 30 条 Now/Next。两个测试均实际执行，未跳过。

### F 追加趋势复核

12 轮虽然未触发冻结的 8 MiB 增量门槛，footprint 从 10.86 MiB 到 14.39 MiB，不能仅凭未超限宣称长期稳定。保留全部原始结果，使用相同 50K 输入、采样点和上限，另开一个独立 Release 进程，将同场景延长至 36 轮观察；仅增加轮数，不变更阈值或取点。

36 轮复核（108 次导入尝试）通过：末轮相对第 3 轮 RSS -0.016 MiB、footprint +3.11 MiB、磁盘 +88.45 KiB、FD 不变；最后 12 轮 footprint 仅 +0.281 MiB，末 6 轮约 15.46 MiB 基本持平。这个趋势支持预热后趋稳，未观察到持续线性累积。没有更改运行时代码，也没有替换/删去原先 12 轮结果；长期稳定性结论限定在已测轮数与负载。

## G：全量回归

OKVideoKit 全量测试：**946 项执行，其中 18 项跳过，0 失败**，约 71.7 秒。显式资源/真实源环境的门禁已另行执行：48 次矩阵、12 轮生命周期、36 轮趋势、公开源 plain/gzip 共 52 次独立验收进程均通过；跳过项不能重复算作通过项。

### G 打包门禁修复

首个候选 `ef888926…` 在 ZIP 解包后签名复验时退出 141，未安装。根因是 `verify-release-signing.sh` 在 `set -o pipefail` 下用 `printf | awk/grep` 提前结束读取，可能导致生产端 SIGPIPE。已改成直接 here-string 输入并去掉 Mach-O 检测的短路管道，没有绕过校验。三项新测试覆盖长诊断正常通过、错误嵌套签名拒绝和禁用 entitlement 拒绝；旧脚本三项均以 141 异常终止，新脚本三项按预期通过，原 ZIP 的 29 Mach-O 真实复验也通过。完整打包以新快照重跑，旧候选及失败日志保留。

Android lint 在构建中输出 Kotlin 2.2 元数据与分析器预期 2.0 的诊断；Gradle Release 构建实际成功。相关 Android 源码/依赖没有因本次 EPG 改动而变化，此诊断保留于打包日志，不解释为 lint 全部无告警。

## 最终交付

版本 **0.7.0（102）**，source SHA256 `1fdd1c4495822d813f1bd30d73fea2930b84504a858b9682aa3fa418cf88100b`。完整 `package-local-acceptance.sh → package-app.sh` 返回成功；Release 构建、bundle、SBOM、敏感信息扫描、29 Mach-O 签名、DMG 与 ZIP 解包验证全部通过。安装副本与打包 App 逐文件字节一致，再次通过 bundle 和签名校验。

- 桌面入口：`/Users/linyao/Desktop/OKVideoMac.app`，非隐藏 symlink。
- 安装目录：`/Users/linyao/Applications/OKVideoMac-Local/1fdd1c4495822d813f1bd30d73fea2930b84504a858b9682aa3fa418cf88100b/OKVideoMac.app`；旧安装目录保留，未强制退出正在运行的旧 App。
- `/private/tmp/OKVideoMac-Acceptance.KhIY6T/Artifacts/OKVideoMac-0.7.0.dmg`，SHA256 `fc8da59e80b1288ac5447d1601d9141604a37a08eb88f707fe37dafffc67247d`。
- `/private/tmp/OKVideoMac-Acceptance.KhIY6T/Artifacts/OKVideoMac-0.7.0-macOS-arm64.zip`，SHA256 `21ef10ddd5605363668a21237fa360cbfbb2b9838d0a7637e0ea358c989cdba6`。

完整证据位于 `OKVideoMac/macOS/OKVideoMac/Artifacts/EPG9C3/`：基线、48 次原始矩阵及摘要、12/36 轮数据、公开样本与出处、各阶段日志、失败打包与修复日志、最终源码快照清单、安装收据和 `ACCEPTANCE.json`。运行时源码与资源验收的 99 个文件逐一对齐。

本地 ad-hoc 测试包，未公证。未提交 Git、未创建 Tag、未发布；没有切换生产 EPG 数据库/配置。下一阶段为 9C.4 的 Repository 与 UI 接入，不能把本阶段 PASS 解读为三个生态所有实际源均已通过端到端生产验收。
