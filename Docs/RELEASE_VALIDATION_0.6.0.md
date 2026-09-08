# OKVideoMac 0.6.0（Build 100）验证基线

日期：2026-09-09。版本、Tag、最终源码 commit 与分发文件的权威绑定以正式 Release
中的 SOURCE_RELEASE_MANIFEST、SOURCE_RELEASE_INDEX 和 SHA256SUMS 为准。

## 自动化结果

| 验证范围 | 结果 | 边界 |
| --- | --- | --- |
| App 全量 XCTest | 719 项，713 通过、6 跳过、0 失败 | 同一构建模块和原生库的独立 XCTest CLI 宿主；Xcode 的 LaunchServices 测试启动在此机器不可用 |
| OKVideoKit | 261 通过、0 失败 | 包括 Xtream 账号、目录、详情、季集、搜索、Live、引用持久化和 HLS 选择 |
| Node / CatPaw / Quark | 30 通过、0 失败 | 实现接口及运行时回归，不代表所有第三方站点 |
| AndroidRuntimeKit | 35 通过、1 跳过、0 失败 | 未重复启用下载完整在线 Runtime 的测试 |
| Android Bridge | Release assemble、lint、AndroidTest APK 构建通过 | JVM unit test 为 NO-SOURCE；不把仅编译的 instrumentation 测试算作已运行 |
| Android API 35 隔离矩阵 | 全部阶段通过 | 冷启动、Bridge、Dex、二次启动、退出、环境隔离 |
| 真实 Android App 生命周期 | 4 项另行执行，全部通过 | 每项独立进程，避免退出状态干扰；使用隔离用户目录 |
| Apple HLS / Mux 302 | App 客户端与实际 OpenGL 渲染门禁通过 | 观察到选中音轨与时间推进；不是所有 HLS/服务商的普遍保证 |
| 文档和版本一致性 | 通过 | 另以旧下载 Tag、旧 Xcode Build、固定 Info.plist 版本进行三个反向验证 |

默认全量运行跳过的四项 Android 测试已经补跑；余下两项外部 Contract B 样本测试
未启用。不得将它们记录为通过。已有的 Node/CatPaw 接口回归结果独立列出。

## 播放边界

完整 App/核心测试包含 TVBox/CatVod、CatPaw/Node、QuickJS、普通直链与本地媒体、
M3U/TXT Live、本地媒体桥、Range/seek、暂停恢复、连续播放及请求所有权回归。
Native Live 的独立策略不会改变普通导入 Live 的 8 秒或 VOD 的 30 秒加载策略。
Native 实例隔离、代理 bypass、取消、旧请求完成和 Provider 切换有针对性验证。
真实第三方 Provider 的内容可用性和网络条件不属于单元测试保证。

## 发布冻结期间修复

- Xtream `get_vod_info` 返回 `info: []` 时使用已有目录信息，仍拒绝非空错误类型。
- Android 私有 AVD 退出校验规范化两侧路径，正确处理系统目录别名；保留 PID、
  出生身份、进程路径与目录边界检查。真实接管/退出测试和目录越界用例均通过。
- 并发测试以 actor 入场屏障等待全部调用者，避免过早释放门闩产生误报。

## 安装与签名证据边界

RC 已通过 Developer ID、Hardened Runtime、Apple 公证、staple、Gatekeeper、DMG
结构和安装副本签名验证。最终分发必须从 main 的 exact release commit 重新执行
同一 package-app.sh 分发流程，以最终资产结果为准。

用户确认安装版界面检查正常并要求跳过重复界面自动化；该项记录为用户确认，
不冒充本轮自动化界面或逐项第三方端到端 PASS。自动化窗口读取曾超时，进程采样
未显示主线程卡死；原始诊断和测试日志只保存在本地验证目录，不随源码分发。
