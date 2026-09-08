# Basic Live Phase 3 — 共享播放生命周期补充决策

> 历史审计记录：以下结论描述 2026-09-08 当时的阶段，不能替代 0.6.0 发布验收。共享播放器所有权及 Native Live 网络保护已实施；`info: []` 缺陷已由 0.6.0 的 empty-VOD 回归修复。当前能力见 [兼容矩阵](../OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

日期：2026-09-08。状态：**待用户确认，未实施共享播放器改动**。

## 为什么暂停

Phase 1/2 使用兼容扩展，不需要重写现有导入直播。但进入 JIT 播放前的只读审查发现：
“复用现有 request ownership 即可保证旧请求无法干扰新请求”的前提不完整。
AppState 的部分状态有请求校验，底层生命周期和关闭收尾却没有形成同一条所有权边界。

这是静态代码证据，不宣称已实机复现。为遵守“架构假设不成立时停止扩大改动”的要求，
本轮不修改共享播放器，也不把带有暂未接入播放入口的 Phase 2 中间状态安装到桌面。

## 代码证据

路径均相对于 `OKVideoMac/macOS/OKVideoMac`：

- `Player/MPVPlayerClient.swift:2607` 的 `prepareForPlayback(requestID:)`
  把请求 ID 用于启动 trace，但等待 teardown/设置后不校验当前请求意图。
- 同文件 `:2656` 的 `closeAfterPlayback(requestID:)`、`:2691` 的 `fullDestroy`
  没有以 request ID 拒绝过时操作；`:2759` 的无参 `stop()` 直接操作当前 client。
- 同文件 `:1035` 的 native `stop()` 只在 `activeMediaRequestID` 存在时等待媒体释放。
  仍在加载、尚未进入 FILE_LOADED 的请求可能立即返回，因此不能把返回视为连接已关闭。
- `App/AppState.swift` 的 `closePlayer()` 在等待 `persistPlaybackProgress()` 后，
  无条件清理播放字段；等待 native close 后又释放所有 lease、关闭播放窗口。
  这些等待之后没有检查是否已有新播放接管。
- `@MainActor` 只保证同步执行片段互斥，不能阻止等待期间新请求进入。

可能的交错：关闭 A → 等待历史保存 → B 开始播放 → A 恢复执行 → 清掉 B 的状态或停止 B。
仅给 Xtream 调用点增加一次 guard，或直接调用原 `fullDestroy`，无法拦截旧 VOD/导入源任务
从其他入口进入无参 stop/close，也不能证明严格的先断后连。

## 建议授权的最小补充范围

不是全局播放队列重写，也不更换 libmpv。只补齐共享生命周期的请求所有权，
并让 Xtream opt-in 使用严格释放策略：

1. 生命周期维护当前 request intent/generation。取得意图后，每个异步等待返回都核对它；
   过时任务只释放自己捕获的资源，不能操作后来出现的 `currentClient`。
2. `stop(ifOwnedBy:)`、close 和 deferred destroy 都绑定 owner/generation。
   把 AppState 中已有 stop 调用、预热和最终 load 接到同一边界，避免旁路。
3. 为 prepare/load 增加默认保持旧行为的 release policy；仅 Xtream 开启
   `destroyBeforeLoad`，等待捕获的旧 client 完成 shutdown，再创建/加载下一路。
   所有新 load 都必须尊重已经存在的释放屏障，但旧源的常规 replace/warm-retention
   策略不因未开启该选项而改变。
4. AppState close 捕获原请求的状态与 lease；异步返回后不清理、不关闭后来请求的 UI。
   不再用无差别 release-all 处理可能已被新请求接管的关闭收尾。
5. 单独为 Xtream 配置媒体 TLS/隐私选项，并以实际 bundled libmpv 初始化和本地服务
   验证。不能把 API 的 URLSession 隔离推导为 libmpv 网络也已隔离。

本地 mpv 源码审查提示 `tls_verify` 默认关闭，且 TLS 证书验证与禁止重定向降级是两个问题。
不能为了不影响旧源而漏掉 Xtream 的验证，也不能未经回归便全局改变旧源 TLS 行为。

## 必须先通过的新增门禁

- A 仍在加载时切 B：A 的 native 释放完成严格早于 B 的媒体请求。
- A close 等待中启动 B：旧 close 不停止 B、不清 B 状态、不关闭 B 窗口。
- A→B→C 快速切换：只有 C 能最终发布和加载；A/B 的成功、失败、取消都无副作用。
- VOD↔Xtream 双向切换：旧 VOD catch 的 stop 不能伤害新 Live，反之亦然。
- 延迟 render detach、关闭失败/取消：不能因超时而放行仍未释放的媒体连接。
- TVBox lease、历史恢复、自然 EOF/下一集、导入 Live、warm retention 保持回归通过。
- 本地服务 access log 证明同时媒体连接不超过 1；仅日志文字顺序不算证据。
- bundled libmpv 隐私选项真实初始化成功，凭据 URL 不落入历史、watch-later 或日志文件。

Basic Live 在以上边界完成前仍不具备 RC 条件。Movies + Series + Search 的既有范围不扩大；
本轮自动回归通过不等于它们已经补做了完整实机 RC 验收。

待确认问题：是否授权把上述“小范围共享所有权加固 + Xtream opt-in 严格释放”
作为独立阶段，在门禁通过后再继续 Basic Live JIT 播放？
