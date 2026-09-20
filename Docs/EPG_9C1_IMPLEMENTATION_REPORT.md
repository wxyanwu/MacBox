# EPG 9C.1 独立存储基础

日期：2026-09-20。阶段范围：人工批次 → SQLite 暂存 → 元数据验证 → 条件启用 → active identity。

## 基线

- 开工前分支：`codex/epg-9b3-download`。
- 开发分支：`codex/epg-9c-storage`。
- 基础 HEAD：`14dd3a584f49bdb67a5b7edd25c9980f77f480e2`。
- 构建源码摘要：`b1a9508d522dd9577fa4f1ffcc5705bffd116095c25d557f02985223a45e57f1`，与 9B.3 交付包的实际源码一致。
- 完整工作区清单：1,560 个文件，清单 SHA-256 为 `2d889220f07f7ba18046e82067c2873172454b2bf5a1fb884507998c458c6f89`。
- 持久基线目录：`OKVideoMac/macOS/OKVideoMac/Artifacts/EPG9C1/Baseline/`。该目录被 Git 忽略，含完整工作文件副本、构建源码快照、tracked/index binary patch、status、逐文件哈希清单。
- 临时副本：`/private/tmp/OKVideoMac-9C1-Baseline-20260920/`。

没有 commit、stash、reset、clean 或覆盖既有文件。本阶段以新增文件实施，收尾再次逐文件验证基线。

## 实现边界

新增 `EPGCacheStore` 和其私有 SQLite 封装，均为 OKVideoPersistence 的 internal 类型，无 App 构造调用。没有连接 XMLTV parser、EPGRepository、用户数据库、节目查询或 UI。

9C.1 表为 sources/resources/generations/programmes。generation 记录 normalization version；频道/别名表及标准化算法由 9C.2 一起加入，避免本阶段预存与既有 matcher 不一致的别名。节目 channel_reference 是原始文本，没有依赖频道声明的外键；节目到 generation 的外键启用。

## 合同

- active_generation 指针是唯一读端依据。诊断 state 错误不能改变读取或触发 active 数据删除。
- begin/append/validate/activate 检查来源、epoch、request、generation 和 store incarnation；每次重新打开产生新 incarnation，旧句柄失效。
- 同源新 revision 撤销旧 revision 的导入资格和 active 引用。同资源刷新期间旧 active 保持可见。
- validate 核对行数、UTF-8 字节汇总、原始 ordinal 范围、时间覆盖；成功后封闭写入。
- 最终 active UPDATE 自带来源、epoch、request 和 validated generation 的条件，changes 必须为 1；事务 COMMIT 成功后才能向调用者返回成功。
- abandon 是显式取消仲裁入口；与 activate 在同一串行队列排序。提交后的 abandon 不撤销 active，也不撤销更新的请求。
- 批次写入失败只回滚当前批次。调用方须显式 abandon 整个导入；重开会撤销所有未完成请求，清理 orphan。9C.3 importer 负责最外层失败清理。
- 默认每批至多 512 条／估算字段 1 MiB，估算为 channel/title UTF-8 字节数 + 每条 64 字节。存储入口独立校验，单条超限拒绝，不截断。
- 每 generation 至多 200,000 条／64 MiB 估算字段，原始 ordinal 单调但允许间隙，主键 generation + ordinal。重复内容不按 programme.id 去重。
- prepared statement 每条 bind/step/reset/clear；显式 UTF-8 长度保留嵌入 NUL。
- 缓存 WAL + synchronous=NORMAL；2 MiB 建议页缓存、mmap 关闭、256 页自动 checkpoint。实际内存需在 9C.3 独立测量，字段预算不等于 RSS。
- 开发阶段数据库主文件默认 max_page_count 对应 128 MiB；DB/WAL/SHM 总量按批次观察，256 MiB 拒绝继续写入。此观察阈值不是瞬时磁盘硬上限。sources/resources/generations 各最多 128 项；sources 保留失效 tombstone。
- GC 一次最多删除 512 条，只选无 active 指针且无有效导入资格的 generation。显式返回节目删除数、generation 是否删除及是否还有工作，空 generation 不会让 GC 误判结束。随后 PASSIVE checkpoint，不强制阻塞 reader，不执行 VACUUM。

## 恢复和文件边界

- 单实例独占 owner.lock；目录必须是当前用户拥有、无 symlink 的专用 EPGCache-* 根，数据库及 sidecar 必须为当前用户拥有的单链接普通文件。
- 目录 0700，数据库及 sidecar 0600；SQLite 错误仅带分类和数字码，不包含 SQL 或绑定内容。
- 用 application_id 区分 EPG cache，foreign database 不删除。
- 已确认 CORRUPT/NOTADB、已识别的不兼容旧版、完整性检查失败：关闭内部连接，在持有 owner lock 时仅移除确切的 DB/WAL/SHM 三个文件，一次重建。
- BUSY、FULL、权限/一般 I/O、较新 schema 不触发删除。较新 schema 返回明确不兼容错误，文件保留。
- 不修改 preferences、sources 用户配置、收藏或历史。sources 表只是此独立缓存的生命周期元数据。
- 启动只标记 orphan；分批删除由 cleanupStep 驱动，避免启动时巨大 DELETE。
- 进程 SIGKILL 恢复测试不代表断电后最后一次提交必然持久化。NORMAL 接受极端系统故障丢失最近缓存刷新。

## 验收

测试包括暂存不可见、旧 active 保留、active 指针权威、请求取代、来源 epoch/revision、封闭验证、UTF-8 和 NUL、重复 ordinal、写入事务中途失败回滚、SQLITE_BUSY、真实 SQLITE_FULL、损坏恢复、旧/新/外国 schema、目录 symlink 拒绝、独占连接、空 generation 清理、20 万节目有界批次。

独立子进程在 appendBeforeCommit、validateBeforeCommit、activateBeforeCommit、activateAfterCommit、cleanupBeforeCommit 五个边界 SIGKILL，重新打开检查 active 数量、清理后的全表数量和 quick_check。每个子进程必须留下命中边界标记且退出原因为 SIGKILL。

并发测试每次由两个全局队列同时 cancel/activate，30 轮要求结果只有已发布或已废弃两种合法状态。

最终测试计数和 Release 交付摘要另存 `Artifacts/EPG9C1/` 的验收记录，避免打包后变更已冻结的构建源码。

## 下一阶段与未声称完成的项目

9C.2 才实现频道匹配、Now/Next 和窗口查询；9C.3 接网络/文件/parser，并测量完整资源矩阵；9C.4 切换生产 EPG。当前没有真实源/窗口 SQL 延迟/完整链路 RSS 门禁结论。

9B.3 证据缺项仍需按最终下载器逐项核对，不能用此次人工批次入库测试替代。它不阻塞独立 9C.1，但进入 9C.3 前必须关闭相关证据缺口。

生产调用冻结意味着本次 Release 的正常 EPG 行为不变，用户数据库不因此创建新缓存或迁移。
