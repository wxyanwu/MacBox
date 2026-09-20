# EPG 9C.3 冻结实施合同

2026-09-20。开发分支 codex/epg-9c-import；基线 HEAD 14dd3a584f49bdb67a5b7edd25c9980f77f480e2。
9C.2 全量测试为 924 项执行，其中 14 项跳过，0 失败。

## 范围与逐关顺序

网络 → 临时文件 → plain/gzip 有界解析 → SQLite staging → validate → activate → 9C.2 query。
生产 EPGRepository、App、UI 留在 9C.4，不实例化新 importer。没有完整 guide/schedule index 回填。
A 基线及证据审计 → B parser → C 本地文件/SQLite → D 网络及协调 → E 故障恢复 → F 资源/真实源 → G 全量回归及 Release。前关失败不得越关。

## 发布合同

复用 EPGCacheImportHandle 作为发布资格：store incarnation/resource/source epoch/request/generation；resource 由 source/revision/resource key 得到。activate 在 writer 串行临界区再次核验资格，条件更新与 COMMIT 成功才是发布成功。
同资源普通刷新失败保留旧 active。来源停用、revision 改变、请求替代与 Store 关闭撤销旧资格。提交成功后的取消不能改写成功状态。
完整合法空 TV（包括有 channel、零 programme）允许发布空 generation；存在 programme 但全部无效仍为失败。空响应、HTML、XML/gzip 截断不得发布。
外层 importer 必须负责失败清理，不能仅依赖 parser discard 或 deinit。abandon 幂等；清理失败不覆盖原错误；提交成功后的 GC 失败不撤销 active。

## 有界合同

下载 32 MiB、展开 XML 64 MiB、原始 programme 200K；节目与频道事实分别最多 512 条/1 MiB 一批，两个缓冲都计入峰值。频道、别名去重留给 SQLite；新入口 summary 只保留计数/时间/字节/峰值，不累计 channels 或 programmeChannelIDs。
有用字段累计时限额，无用文本不累计；超限失败不截断。旧 Data parser 行为由独立 oracle 保护。Foundation XML token 内部开销靠实测验证，不冒充应用可控制的硬上限。
同步 sink 返回后才能继续解析，无 per-batch Task 或无界 stream。单 Store 一条流水线，待处理最多四个轻量请求；普通同资源请求合并，强制刷新取消/排空旧任务再执行。
后台执行器显式传播取消，不依赖 GCD 自动继承 Swift Task 状态。SQL 验证取消由 writer 自己的 operation 控制，不能复用 reader interrupt。

## 测量协议 v1（正式采样前冻结）

设备 iMac21,1 / Apple M1 8 核 / 16 GB；macOS 14.8.9 (23J631)。Xcode / Swift 版本与 Release 二进制 SHA 在每次运行清单记录。设备或协议变化需保留旧结果并重跑完整相关矩阵。
固定 10K/50K/100K/200K；紧凑 plain 200K ≤32 MiB，其 gzip 使用相同逻辑内容。外部生成器生成 fixture 并冻结 SHA256，服务端独立进程，不计入客户端内存。
每种规模/格式/场景三次独立 Release 进程；全部原始结果、最大值、中位数均报告。RSS/phys_footprint 每 10 ms 采样并在阶段边界补采；磁盘与 FD 每 100 ms 采样，文件所有权边界补采。Foundation 临时文件占用从下载进度与 pinned fd 的 fstat 字节数计算，直到复制结束关闭该 fd；应用文件由私有根枚举统计。采样峰值不是数学上的瞬时硬上限。
cold 指新进程/新缓存，非清除 OS 文件缓存。warm 指同进程有 active、完成一次预热后刷新。首次测量 baseline 在运行时就绪、Store 打开前；刷新 baseline 在预热成功并完成有限 GC 后。测量覆盖下载、文件复制、解析、写入、验证、启用、文件释放及 GC，排空后再采 1 秒。
GC 单步沿用 512 行；循环步数与时间记录。连续刷新/失败/取消记录每轮清理后的驻留与磁盘，验证空间复用及无持续线性增长。
200K RSS/footprint 峰值增量分别 ≤32 MiB；50K→200K 三次最大峰值增量之差分别 ≤8 MiB。plain/gzip、cold/warm 分别比较，不跨组取数。100 频道 Now/Next 与单频道 500 行窗口 P95 ≤50 ms；刷新期间查询单列同门槛。查询异常分布允许明确 queryBudgetExceeded，不允许伪报空结果。
取消本地工作停止延迟与 Foundation 完成/释放延迟分开记录。资源门禁不排除失败采样，不因结果修改统计法。
DB/WAL/SHM 256 MiB 是观察阈值，系统下载临时文件+staging+新旧 generation 都计入全链路磁盘测量；不宣称 256 MiB 为总硬限。

## 9B.3 证据审计

最终 XMLTVDownloaderTests 已有响应准入、plain/gzip、声明与未知长度超限、取消、单次文件所有权测试。已有 200K gzip 回环证据；41 MiB plain 只有拒绝证据。
9C.3-D/E 必须补最终下载器真实回环的重定向上限/跨源敏感 header、超时、复制失败及完成取消竞态；不得用早期下载实验代替。紧凑 plain 正向容量在 F 补齐。
真实源仅使用已授权可取得样本；记录脱敏 fixture 与哈希，不泄露地址/凭据。无样本的生态注明未验证，不以合成样本替代真实证据，未通过门禁不得写完整 PASS。

## 交付

基线含 1568 个 tracked/untracked 工作文件、Git patch/status、9C.2 验收文件；位于忽略的 Artifacts/EPG9C3/Baseline。清单 SHA256 a0333a157f2ce2a3da93a5a3f8fc97d79dabfff0ff2f61ccb49a07822fbd4352。
G 通过后使用 package-local-acceptance.sh 调用 package-app.sh 生成验证 Release，验证通过才替换 Desktop。原始日志/测量/验收及交付哈希归档，不提交 Git/tag/发布，不动用户数据库与配置。

## F 补充验收协议（补充场景执行前冻结）

独立 Release 进程执行 12 轮：每轮同一 50K fixture 成功刷新，再分别在首批提交后注入 sink 失败和主动取消，均检查 active 保留、有限 GC 排空、临时文件释放。报告每轮 RSS/footprint/磁盘/FD，末轮相对第 3 轮驻留和磁盘差分别不超过 8 MiB、FD 差不超过 2；局部取消从 stop 到清理返回 <1 秒。
额外导入 20K 唯一频道 + 同一频道的 20K 别名（40K metadata facts），检查 20,001 唯一频道和空 programme 发布，内存峰值增量仍分别 ≤32 MiB。
公开真实源小样本以旧 Data parser 作为独立 oracle，逐行比对完整 programme，频道 ID/显示名匹配及 Now/Next 抽样与旧语义一致。真实源 oracle 测试不用于大容量内存数字。
