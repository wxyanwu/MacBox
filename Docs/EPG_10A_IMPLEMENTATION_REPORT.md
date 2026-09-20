# EPG 10A 实施与验收记录

日期：2026-09-20。冻结方案见 `EPG_10A_REVISED_IMPLEMENTATION_PLAN.md`。

## 当前阶段

10A-A 已完成并通过；下一步为 10A-B 纯数据模型、协调器和有限接口补全。B 通过前不开发 AppKit 网格。

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
