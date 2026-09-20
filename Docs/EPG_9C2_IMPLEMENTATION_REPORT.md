# EPG 9C.2 有界查询层

日期：2026-09-20。阶段范围：人工 generation → SQLite active snapshot → 频道匹配／批量 Now/Next／有界窗口分页。

## 基线与分支

- 9C.1 开工分支为 `codex/epg-9c-storage`，9C.2 开发分支为 `codex/epg-9c-query`，基础 HEAD 保持 `14dd3a584f49bdb67a5b7edd25c9980f77f480e2`。
- 9C.1 的四个新增文件、实施报告、验收记录及 9B.3 完整工作区清单复制到被 Git 忽略的 `OKVideoMac/macOS/OKVideoMac/Artifacts/EPG9C2/Baseline/`。复制件哈希与 9C.1 `ACCEPTANCE.json` 完全一致。
- 没有 commit、stash、reset、clean 或覆盖既有未提交工作。

## 行为合同

9C.2-A 先以现有 `XMLTVChannelMatcher` 和生产实际使用的 `XMLTVScheduleIndex` 建立独立 oracle：

- 非空 `tvgID` 只做精确 ID 匹配，未知 ID 不回退名称。
- 精确 ID 采用 Swift String 的 Unicode 规范等价语义；SQLite 保存 NFC `channel_key` 并只做 BINARY 精确比较。
- 名称继续采用既有 NFKC、空白、POSIX 大写、CCTV 及高清后缀规则，不新增模糊匹配、繁简转换或其他猜测。
- 只出现在 programme 中的频道 ID 同样是 known channel，并由 ID 产生名称别名。
- `name` 与 `tvgName` 的候选先合并；两个不同频道即为 ambiguous，不取第一项。
- Now 使用 `[start,end)`，选择 `start DESC, ordinal DESC`；Next 使用 `start > now`，选择 `start ASC, ordinal ASC`。节目空档不推断当前节目。

共享标准化函数由 in-memory matcher 和 SQLite writer 共用，对照测试确认重构没有改变旧行为。

## schema v2 与写入生命周期

独立缓存 schema 升为 v2。新增 `channels` 与 `channel_aliases`，`programmes` 增加 `channel_key`，时间索引为 `(generation_id,channel_key,start,ordinal)`。

- `channels` 主键为 `(generation,channel_key)`；原始频道 ID 单独保留。
- `channel_aliases` 主键为 `(generation,normalized_alias,channel_key)`。同一频道重复别名去重，不同频道同名保留，因此查询只需每个 alias `LIMIT 2` 即可判断歧义。
- programme 批次自动增量建立 programme-only 频道及 ID 别名；频道声明可分批补充 display name 和 aliases。
- generation 记录频道声明条数、去重频道数、别名数和实际 UTF-8 元数据字节。validate 同时核对 programme、channel、alias、字节汇总、时间覆盖和外键完整性，之后整体封口并原子启用。
- 元数据单批 512 条／1 MiB；generation 最多 400,000 个 known channel、800,000 个 alias、64 MiB 元数据。超限整批回滚，不截断或静默丢弃。
- cleanup 的单步预算由 programme、alias、channel 共用，先删子记录，全部为空才删 generation；没有大规模 cascade。
- v1 是可识别的独立缓存旧 schema，按既有安全规则重建；用户配置、历史、收藏及用户数据库不参与。

## Reader、快照与查询 API

一个 `EPGCacheStore` 管理一个 writer connection 和一个串行 reader connection。Reader 以不带 CREATE 的现有数据库方式打开，启用并验证 `PRAGMA query_only=ON`，不执行迁移、恢复或 checkpoint。

每个操作使用短读事务：先解析 active generation 形成统一 `EPGQuerySnapshotID`，再完成匹配和节目读取。同一次查询只看到一个 WAL snapshot；refresh 中途提交不会混合 generation。结果携带 store incarnation、resource、source epoch 和 generation。

查询能力包括：

- 最多 100 个频道的匹配和批量 Now/Next；结果累计最多 2 MiB，不能部分返回后续频道。
- 单频道窗口最多 24 小时，默认 200、最大 500 条；条件为 `start < upper && end > lower`。
- 窗口按 `(start,ordinal)` keyset 分页，不使用深 `OFFSET`。cursor 绑定版本、snapshot、频道、窗口和最后返回行，并验证锚点行确实存在。
- 字节预算不足以容纳下一条时，返回当前完整页及 cursor；单行超过预算返回 `resultTooLarge`，不截断字段。
- active generation、source epoch、resource 或 store incarnation 改变后，旧 cursor 返回 `snapshotChanged`，调用方从第一页重新读取。

没有构造 `XMLTVGuide`、完整 programme array 或 `XMLTVScheduleIndex`，也没有在 MainActor 上执行 SQL。

## 队列、取消和执行保护

- 第一版只有一个 reader executor，同一时刻一个 active query；运行加等待最多 8 个，第 9 个立即返回 `queueFull`。
- 每次 query 有独立 cancellation token 和 interruption ownership。用户取消、VM work budget、Store 关闭分别映射为 `cancelled`、`queryBudgetExceeded`、`storeUnavailable`。
- progress handler 在整个 query operation 内累计工作，不会对每个频道重置预算；handler、statement、read transaction 和 active ownership 全部清理后下一条查询才能运行。
- Store 关闭先进入 draining，标记并中断 active query，拒绝新查询，等待 reader queue 释放以后才关闭 connection。
- 默认 VM 指令预算为 2,000,000，progress 检查间隔 1,000。它保护异常数据分布，不宣称任意合法 200,000 条分布都能固定步数成功。
- 每次查询记录 VM steps、full-scan steps、sort、automatic-index rows 和 statement memory，供资源门禁验证。

## 验收结果

阶段测试覆盖 Unicode ID、programme-only channel、别名歧义、时间边界、重叠与同起点 ordinal；metadata 封口、批次回滚、combined GC；refresh 快照一致性、分页不重不漏、伪造／换代 cursor；取消恢复、队列满、关闭排空和错误分类。

Release 资源门禁使用增量批次生成数据，没有预先构造完整节目数组：

| programme 数 | 100 频道 Now/Next P95 | 窗口查询 P95 | 重复查询 footprint 增量 | 窗口 VM steps |
|---:|---:|---:|---:|---:|
| 10,000 | 0.705 ms | 0.130 ms | 32 KiB | 1,771 |
| 50,000 | 0.667 ms | 0.420 ms | 32 KiB | 8,571 |
| 100,000 | 0.722 ms | 0.466 ms | 32 KiB | 8,584 |
| 200,000 | 0.674 ms | 0.460 ms | 0 | 8,584 |

`EXPLAIN QUERY PLAN` 使用 `programme_time`；实际 statement counters 的 full scan、额外 sort 和 automatic index 均为 0。200,000 条异常矩阵同时覆盖全部过期、全部未来、大量重叠、一个长节目加大量已过期短节目；快速路径返回正确结果，扫描型路径在测试预算下明确返回 `queryBudgetExceeded`。

OKVideoKit 全量回归：924 个测试执行，14 个按显式实验门禁跳过，0 失败。两个 9C.2 资源门禁测试已在独立 Release 命令中实际执行并通过，不以全量回归里的 skip 代替证据。

## 阶段边界

9C.2 的类型仍为 OKVideoPersistence internal，App、`EPGRepository`、UI 和生产 parser 都没有构造或调用这套缓存。当前结论只证明人工批次写入后的 active SQLite generation 能正确、有界地读取。

9C.3 才连接 9B.3 的网络文件、gzip/plain 流式 parser 和 importer，并测量完整链路 RSS、磁盘、取消、失败回滚和真实源矩阵。9B.3 尚未关闭的证据缺项也必须在进入 9C.3 时关闭。9C.4 才切换生产 Repository/UI。

阶段结论：**9C.2 PASS：SQLite active generation 已具备频道匹配、批量 Now/Next 和有界时间窗口分页能力；查询不构建完整节目对象图。尚未接入流式 importer，尚未切换生产 EPG 路径。**
