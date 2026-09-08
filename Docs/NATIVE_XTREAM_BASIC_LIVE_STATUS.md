# Native Xtream Basic Live — 阶段交接

> 历史审计记录：以下结论描述 2026-09-08 当时的阶段，不能替代 0.6.0 发布验收。共享播放器所有权及 Native Live 网络保护已实施；`info: []` 缺陷已由 0.6.0 的 empty-VOD 回归修复。当前能力见 [兼容矩阵](../OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

更新：2026-09-08。**Phase 1–4 实现、自动回归、Debug/Release 黑盒与本地 Release 包验证已完成；
验证通过的 Release 已安装到桌面，最终 Keychain 授权、账号切换、冷启动与 Live 回退复测均通过。**

用户已确认 `NATIVE_XTREAM_BASIC_LIVE_PLAYER_GATE.md` 中的小范围共享生命周期补充方案。
Phase 3 已完成播放器 request ownership/release barrier、Xtream Live 播放前即时认证与
URL 解析、同频道格式有限恢复，以及 bundled libmpv 隐私/TLS 能力门禁。Phase 4 已完成
Xtream Basic Live 与导入 M3U/TXT/JSON 的实机黑盒，并产出通过全部本地打包门禁的 Release。

## 工作区与边界

- 分支：`codex/full-app-localization`。
- HEAD：`475845727b41b2688fb7a7a0a2ce74afe340a570`，未提交本轮改动。
- 工作区本来已有 Native Xtream Movies/Series/Search 和返回按钮修复等未提交改动，
  均予以保留；不能把整个 `git diff` 当成本轮新增内容。
- 不修改 Version/Build，不 tag、push、merge、notarize 或发布。
- 当前交付边界、身份和安全合同见 `NATIVE_XTREAM_BASIC_LIVE_CONTRACT.md`。

## 已落盘的 Phase 1 内容

1. 命名空间来源 ID、纯数据 descriptor、内存 catalog snapshot。
2. 可选显式 Group/Channel ID，保留导入源原有名称身份和编码兼容。
3. `LiveStreamTarget.direct/provider`；provider 不提供直接 URL。
   默认请求头只作用于 direct，后台 URL 探测拒绝 provider。
4. schema-2 Live reference 与版本化 Xtream Live locator；严格绑定 Provider，
   不借用 Movie/Series source/episode 身份，旧 episode 编码保持原样。
5. 版本化频道引用 envelope：保留旧字符串、未知成员；未知根结构只读。
   Phase 2 已接入 AppState 收藏/隐藏设置，旧设置未迁移或覆写。
   最后复核将原始 JSON getter 限制为 `fileprivate`，避免公共调用绕过 ID 校验；
   对外仍可使用经过校验的 Codable 和 envelope 接口。对应测试改用公共编码路径，
   此收口已在恢复后的 240 项及后续 249 项包回归中验证。
6. Xtream 专用无 Cookie、无缓存、无系统凭据存储的 ephemeral HTTP client，
   已接入认证和 Provider 构造。通用 HTTP 默认行为不变。

provider target 仍不能直接穿透播放器；必须经 AppState 的 Xtream JIT 路径读取当前
Keychain 凭据、重校验账号并解析为本次播放专用的运行时 `ResolvedMedia`。

## 已完成的 Phase 2 内容

- Live category/stream API 和兼容 DTO；只拉两类 metadata，无媒体或 EPG 探测。
- 当前激活 Provider 的动态来源与内存目录；同名分类分离，频道改名、换分类和换格式
  不改变 Provider/stream 身份；缺分类有稳定兜底，重复 ID 确定性去重。
- AppState 用请求 ID、来源和配置代际隔离目录结果；刷新旧成功/失败均不能覆盖新请求。
  账号改密/删除期间阻止新目录请求，Provider 重建与退出会取消旧目录任务。
- 新收藏/隐藏 SQLite 设置独立，写入串行且成功后发布；未知值保留。Native 隐藏保留收藏，
  “恢复全部”仅作用于对应 Provider。导入源仍走旧方法、旧字符串和旧设置。
- LiveView/快捷切换器使用 namespaced descriptor 和 group ID；目录失败或加载中
  来源菜单仍保留。Xtream 禁用 EPG、后台频道探测、第三方频道名 logo fallback。
- UI 中 Xtream 的播放入口已接入 JIT；其 Phase 4 实机黑盒结果与最终 Release 状态记录在下文。

## 已完成的 Phase 3 内容

- `PlayerLifecycleController` 对 prepare、严格释放、stop、close、destroy 和 load 统一串行；
  旧 request 的 stop/close 不能破坏后到的新播放，严格模式在凭据读取前销毁旧 client。
- AppState 所有 player stop/close 均带 request ownership；并发 close 会等待同一关闭事务
  完成，不再出现旧关闭任务越权销毁新播放器。
- Xtream Live 点击播放时才从 Keychain 读取当前凭据；随后只调用 account metadata 认证，
  不对媒体做 HEAD/Range 预探测，再按稳定 stream ID 生成标准 `/live/` URL。
- `status=Active` 但 `exp_date` 已过期的账号现在按 `Expired` 拒绝；Disabled/Expired 在媒体
  URL 生成前结束，不能错误触发 HLS/TS 格式轮换。
- Xtream 自动恢复仅限当前频道的 HLS/TS 候选；导入 M3U/TXT/JSON 继续保留原有整来源
  恢复语义。Provider 保存、删除、配置切换/导入/恢复均先关闭相关 Xtream 播放并使代际失效。
- HTTPS Xtream Live 每次 load 显式设置 `tls-verify=yes`。mpv 的配置、终端、watch-later/
  历史与脚本相关持久化选项按 bundled libmpv 能力禁用：硬性选项失败即拒绝初始化，缺失的
  可选加固项仅在原生明确返回“option not found”时跳过。

## 已完成的 Phase 4 内容

- 临时 Mock 新增 Live fallback 测试账号，覆盖 HLS 分片拒绝、manifest 403、
  HLS/TS 双失败和延迟分片拒绝；扩展只存在于 本机临时目录，未修改 IPTVnator 原仓库。
- HLS 失败的三个可恢复样例均只在同一 stream ID 内回退到 TS，首帧分别约 359 ms 或更快；
  H.264、VideoToolbox 与 0/0 decoder/renderer dropped frame 均正常。双失败样例停留在原频道
  并显示错误，没有跳到相邻频道。
- Xtream 动态目录显示 4 频道/1 分类；筛选、搜索、收藏、刷新均通过。
- 导入 M3U/TXT/JSON 分别从正常 UI 播放到首帧（约 174/192/237 ms），均为 H.264、
  VideoToolbox、0/0 dropped frame；旧分组、筛选、收藏/隐藏、刷新和直接 URL 路径未被
  Xtream 身份或恢复策略替换。
- 过期账号兼容缺陷已做最小修复：认证、保存、启动、Home 加载和配置切换共用过期判定；
  `status=Active` 但正数 `exp_date` 已过期时明确返回 `Expired`，不能借缓存继续启用。
- 打包敏感扫描发现的三项均为测试代码中的长合成密码；只把测试夹具换成短合成值并同步
  期望，未降低扫描规则或增加豁免。相关 Core 22/22、App 4/4 复测和最终两轮扫描均 CLEAN。
- 本地 ad-hoc Hardened Runtime Release 0.5.0 (99) 完成 App、29 个 Mach-O、源码归档、
  SBOM、ZIP、DMG、签名、源码—二进制绑定和两轮敏感信息扫描验证；未改 Version/Build。
- 桌面原 `OKVideoMac.app` 只有 iCloud 占位文件、缺少主可执行文件；已可恢复地移到
  本地历史审计记录（不随源码分发），并安装验证包。
  空的 `OKVideoMac 2.app` 未删除。
- 用户完成系统 Keychain 授权后，桌面 Release 启动时明确拒绝已保存的 `RC expired`；
  `RC Basic Live` 可正常激活并加载 4 个频道。直接 TS 播放成功，从 UI 选择失效 HLS
  后仅在同一频道自动回退到 TS，播放器显示恢复提示并继续播放。
- 再次尝试激活 `RC expired` 时明确返回 `Expired`，且当前 `RC Basic Live` 未被替换；
  退出并冷启动后仍恢复该有效配置，Home 正常加载 4 个内容项。
- 最近 20 分钟统一日志只读扫描未发现用户名/密码查询参数、Mock 密码或含凭据的 Live path；
  同一日志记录 6 次首帧与 3 次 VideoToolbox 启用事件。
- 最终收尾验签发现 Finder 为桌面包根附加了 `com.apple.FinderInfo`；仅移除该项可重建元数据后，
  App 与全部内嵌框架再次通过 `codesign --verify --deep --strict`，二进制和签名内容未改变。

## 已有证据与剩余门禁

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| Phase 1 OKVideoKit 最终回归 | 恢复后 240 项、0 失败 | 本地历史审计记录（不随源码分发） |
| Phase 1 App 回归 | 679 项、5 跳过、0 失败 | 本地历史审计记录（不随源码分发） |
| 模型/引用存储及旧 parser/loader 精选回归 | 暂停请求前已完成：23 项、0 失败 | 本地历史审计记录（不随源码分发），包含于相关测试覆盖，不能与 240 简单相加 |
| App 与测试 target 最终编译 | 通过，**没有执行测试** | 本地历史审计记录（不随源码分发），`TEST BUILD SUCCEEDED` |
| OKVideoKit 测试代码最终编译 | 通过，**没有执行测试** | 本地历史审计记录（不随源码分发），`swift build --build-tests` 成功 |
| 空白/补丁检查 | `git diff --check` 通过 | 静态检查，不是功能测试 |
| 新增 App prober 回归 | 已通过，包含于 App 回归 | `testProviderLiveReferenceIsNeverOpenedByBackgroundURLProbe` |
| Phase 2 OKVideoKit 全回归 | 249 项、0 失败 | 本地历史审计记录（不随源码分发） |
| Phase 2 App 全回归 | 693 项、5 跳过、0 失败；新增 14 项全部通过 | 本地历史审计记录（不随源码分发） 及同名 `.xcresult` |
| 10k Live 目录转换 | 1.137 秒，只有 2 个 metadata 请求 | 包内 `XtreamLiveCatalogTests`；不是 100k Live 实机证明 |
| Phase 3 OKVideoKit 全回归 | 253 项、0 失败 | 本地历史审计记录（不随源码分发） |
| Phase 3 播放器/恢复精选门禁 | 7 项、0 失败；包含真实 bundled libmpv 初始化/关闭 | 本地历史审计记录（不随源码分发） 及同名 `.xcresult` |
| Phase 3 App 常规全回归 | 700 项、5 跳过、0 失败 | 本地历史审计记录（不随源码分发） |
| Phase 3 后 OKVideoKit 全回归 | 254 项、0 失败 | 包含过期账号在 Home 前拒绝的新增测试 |
| 最终 App 常规全回归 | 700 项、5 跳过、0 失败 | 本地历史审计记录（不随源码分发）；明确排除两个外部真实 Android E2E |
| 测试夹具扫描修订复测 | Core 22 项、App 4 项，0 失败 | 本地历史审计记录（不随源码分发）、本地历史审计记录（不随源码分发） |
| Android 显式真实退出 E2E | 环境阻塞，单独运行失败；不计入 Xtream 门禁 | `/Volumes/XcodeDev/AndroidSDK/platform-tools/adb` 内容读取阻塞，`file`/`otool`/`codesign` 同样无法完成；`android-real-termination-retry.xcresult` |
| Xtream Basic Live 实机黑盒 | 通过 | 4 个失败/回退场景、目录/筛选/搜索/收藏/刷新、同频道有限回退、无相邻频道跳转 |
| 导入 Live 实机回归 | 通过 | M3U/TXT/JSON 的分组、筛选、收藏/隐藏、刷新与实际播放；首帧、VideoToolbox、0/0 dropped frame |
| 本地 Release 全打包 | 通过 | 本地历史审计记录（不随源码分发）；App/ZIP/DMG/源码归档/SBOM/签名/两轮敏感扫描全部通过 |
| 桌面 Release 安装 | 通过 | `$HOME/Desktop/OKVideoMac.app`，0.5.0 (99)，arm64，`codesign --verify --deep --strict` 通过 |
| Release Keychain、切换与 Live 回退复测 | 通过 | 用户完成系统授权；过期启动/激活均被拒绝，有效配置保持并通过冷启动；Release UI 的 HLS→TS 同频道回退实际开始播放，目录为 4 频道 |

表中早期编译使用 Debug `build-for-testing`，仅用于诊断；最终交付另行使用已验证的
Release 包并已安装到 Desktop。App 运行测试中，显式启用的真实 Android 退出集成用例因外部 XcodeDev 卷上的 ADB
二进制内容读取持续阻塞而失败；普通全量回归明确排除该外部环境 E2E 后为 700/0。
该问题单独归因，不修改 Android 代码、用户安全策略，也不把环境问题归为 Xtream 缺陷。

## 剩余门禁与范围

1. emptyvod 测试账号 的空 VOD metadata 数组仍是 Movies 核心 RC blocker；本轮未获准
   修改，详见 RC 报告。它不属于 Basic Live 回归，也不能用 Basic Live 通过来豁免。
2. `/Volumes/XcodeDev/AndroidSDK/platform-tools/adb` 的外部卷读取阻塞应在环境恢复后补跑
   两个真实 Android E2E；常规 700 项 App 回归已通过。

当前只停在 verified local RC / implementation report。没有修改版本号或 Build，没有 tag、
push、merge、notarize、GitHub Release 或正式发布。Basic Live 不扩展到 Native Xtream EPG、
频道导出或旧导入源身份迁移。
