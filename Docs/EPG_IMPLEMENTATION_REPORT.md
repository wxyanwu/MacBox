# EPG Implementation Report — 7A 本地验收候选

## 发布门禁

状态：1～6 与 7A 已完成，停止等待人工验收。7B 尚未获批。
没有修改 0.6.1 / Build 101，没有替换 Desktop App、正式公开 DMG，没有 tag、
push、GitHub Release 或公告。验收候选保留原版本号，不能仅凭版本号区分正式版。

## 1. Baseline（2026-09-10，实施前）

- 原仓库 main，HEAD：14dd3a584f49bdb67a5b7edd25c9980f77f480e2。
- 用户已有修改：Docs/DemoSource/README.md（4 行增加）及未跟踪
  Docs/DemoSource/v0.6.1/；未改动、未纳入验收源码快照。
- OKVideoKit：261 passed / 0 failed，5.937 秒。
- 原有 10K Live 映射：1.127 秒；10K/100K VOD stress：2.008 秒。
  这些是单次测试运行，不是滚动、首帧或换台延迟的端到端测量。
- 安全基线：Keychain 持有 Native 账号；持久配置和播放引用不含 credential；
  Native 使用隔离临时 HTTP session；目录测试不请求 EPG 或媒体。
- 没有读取真实账号、真实 Keychain 值，也没有连接真实 Provider。
- 没有实施前完整 Xcode 测试/Release 包基线，也没有真实滚动/首帧的量化基线。
  不把实施后的测试结果冒充实施前数据。
- 基线日志：/private/tmp/okvideomac-epg-baseline-tests.log。

## 2. 变更单及逐步验证

| 变更单 | 实现 | 验证 |
| --- | --- | --- |
| 1 | 记录 Git、用户改动、核心测试、性能与安全边界 | 261 项核心测试 |
| 2 | EPGSourceKey / EPGRequestKey / 不可变 snapshot / NowNext 与进度 | 2 项模型测试 |
| 3 | 一个 EPGRepository actor 承担缓存、单飞、取消、失败退避 | 初始 4 项仓库测试；后补旧缓存迁移 |
| 4 | XMLTV 接入新仓库；UTC/offset；gzip/XML 取消、错误页面拒绝；名称歧义保护 | 中间 21 项 EPG/XMLTV/LiveSource 测试；最终全量复验 |
| 5 | Native get_short_epg，时间/base64/空值容错，JIT credential，保留 epg_channel_id | 中间 80 项 EPG/Xtream/XMLTV 测试 |
| 6 | Live 和播放器信息卡 Now/Next、时间、进度、边界时钟；浏览级有界预取；睡眠恢复 | Debug build；新增 5 项 App EPG 测试；全 App 回归两轮 |
| 7A | 核心/App 完整回归、本机样本、安全和范围复核、本地 Release | 见下面结果及验收包记录 |

每一单均执行了对应测试和 git diff --check。最终只在播放器展示层修改 EPG
信息卡，没有修改 Player/ 核心目录或 playLive / switchLiveChannel 的等待链。

## 3. 实现契约

### 身份与 Provider 隔离

- 不改变 LiveChannel.id。
- EPG key = source kind + source UUID + revision + resource。
- XMLTV resource 固定为 xmltv；revision 为 EPG URL 的 SHA-256。
  同一源、同一 EPG URL 的 M3U 刷新复用旧表，URL 变化立即清空旧显示。
- Native resource 为实际播放引用中的 streamID，不使用频道显示名猜测。
  epg_channel_id 作为可选 tvgID 元数据保留，不作为 Native 短 EPG 请求主键。
- Native revision 为安全配置描述符与 updatedAt 的摘要。账号修改（包括只改密码）
  更新 updatedAt，并在修改期间失效该 Provider 缓存及界面状态。
- App generation + 当前 revision 校验拒绝迟到结果；Repository flight ID
  阻止被取消/失效的请求写回。Provider 切换立即清空 Native 展示状态。

### 缓存、错误和时效

- 一个 actor，没有为了 Full Guide 建四套额外抽象。
- 新缓存位于现有 Caches/EPG/v1；旧 URL-keyed XMLTV 缓存按摘要迁入
  source namespace，原文件保留。损坏缓存允许网络恢复。
- 内存每层最多 32 条 / 400,000 programmes；单表最多 200,000 programmes。
  磁盘最多 128 个 JSON / 128 MiB，单文件读取限 80 MiB，文件 0600、目录 0700。
- XMLTV 默认 6 小时；Native 默认 5 分钟；临近覆盖终点提前检查。
  当前使用频道覆盖不足可触发刷新。App 每 30 秒检查有需求的节目表。
- 有效空响应缓存 15 分钟；明确 unsupported 1 小时；失败重试退避 60 秒。
  错误响应、全无效数据、解析失败保留上一份有效表并标记旧缓存。
- 过期节目不会继续冒充“当前节目”；旧表没有覆盖当前时间时显示暂无节目。
- XMLTV：HTTP body 32 MiB，解压后 64 MiB，禁止外部实体解析。
  Native short EPG：1 MiB 早期限流，同源且禁止降级重定向。
- Native 原始 JSON、请求 URL、用户名和密码不进入 EPG 缓存；仅保存经处理的
  节目标题、时间、streamID。错误不会把 credential-bearing URL 发布给 UI。

### 调度和 UI

- 单个 utility 后台任务；浏览变化 150 ms 合并；当前播放频道优先，然后当前
  使用的浏览组/搜索结果最多 8 个频道。串行请求，按完整 key 去重，需求变化取消。
- 无新增 GeometryReader/PreferenceKey 可见性追踪，无逐卡片网络 task，
  无 onAppear/onDisappear 卡片请求，无完整目录相等性观察。
- 预取使用 lazy filter + prefix，够 8 个就停止扫描；不追求精确 viewport。
  未预取到的 Native 卡片可能暂无节目，播放时会优先获取。
- EPG snapshot 独立于 AppState 大对象的发布；更新的是 EPG 小视图，
  不按时钟刷新整个 LazyVGrid。
- 时钟 15 秒进度节拍，加入已知当前/下一节目的开始/结束边界；UI 用设备时区
  显示，所有判断使用绝对 Date。App 激活和 Mac 唤醒立即重新计算。
- Sleep 取消 EPG 请求；Wake 的 EPG 恢复不依赖播放器是否需要恢复。
  无退出后任务、LaunchAgent、BGTask、daemon。
- Native 时间戳优先；仅有无偏移字符串时请求 Provider server timezone，
  未知时区不猜成本机时区。支持 base64/plain 标题与 string/number 秒级时间戳。

## 4. 自动验证结果

- OKVideoKit 最终：275 passed / 0 failed，6.352 秒。
  /private/tmp/okvideomac-epg-final-core-tests.log。
- Xcode Debug 完整 App：726 total / 719 passed / 7 skipped / 0 failed，
  最后一轮 40.521 秒。
  /private/tmp/okvideomac-epg-app-final-tests.log。
- 新增 App 测试：revision/删除后迟到发布拒绝、import/native 同 UUID 隔离、
  精确边界节拍、长时间睡眠后的 NowNext/进度重算、UI snapshot 数量限制。
- 最终 XMLTV 错误页面防护修正后，再次 Debug build + 5 项 EPG 集成测试通过。
  /private/tmp/okvideomac-epg-final-integration-tests.log。
- 7 个跳过项：真实 Contract B 配置/样本（2），真实 Android External/
  startup cancellation/private AVD（3），明确要求公网和渲染器授权的 Native
  Apple/Mux（2）。不能视为这些真实系统集成已通过。
- 初次新增 App 测试因 Swift 参数顺序编译失败，修正后两次全量通过。
  没有跳过失败测试。
- 本机样本 7 项 HTTP 检查通过：M3U、有/无 EPG、XML、Native 目录、
  短节目、空节目、媒体；测试服务验证后已停止。
- 已有弃用/Swift 6 迁移类 warning 保留，不改播放器/WebKit 等无关代码。
- 性能数字只用于发现明显回归，不能证明滚动不掉帧。真实滚动、首帧、
  快速换台和 Provider 长尾响应仍是人工门禁。

## 5. 本地打包与源码对应

原 package-app.sh 首次被既有文案检查拦住：检查器要求发布前措辞，
README 已使用相同版本号的稳定版措辞。仅修正 check-doc-status.sh，
兼容两种措辞，仍严格校验版本、Build、tag 和其余发布资料。
检查脚本语法和当前文档校验均通过，正式发布文档未改动。

源码打包要求 clean Git。为保留用户工作树，在临时目录以原 HEAD 加本轮
文件创建独立干净快照；仅该临时仓库有本地验收提交，原仓库不提交。
Release 从快照构建，继续执行原 package-app.sh --mode local 的全部
签名、bundle、SBOM、源码/二进制对应、敏感信息和 DMG 校验。
本地验收文件统一输出 build/EPGAcceptance-20260910，不作为公开发布物。

### 最终结果

- 原脚本完整运行成功：Release clean build、bundle、29 个 Mach-O 的本地
  Hardened Runtime ad-hoc 签名、SBOM、源码/二进制绑定、DMG 校验、
  敏感信息扫描 CLEAN。未公证；未执行适用于正式分发的 Gatekeeper 验收。
- 快照 commit：753f4b420bdafc376fb4a6c431d04afbcb752de7。
  源码归档包含本轮代码及打包前报告草稿；本文件及人工说明在打包后补充了结果/路径，
  不改变已验证二进制。代码与快照逐文件相同。
- Android Bridge 复用已有 Release APK，未修改 Android 源码；原打包脚本继续
  校验 exact APK 和源码/依赖对应关系。
- Documents 文件同步服务给独立 App 重新附加 Finder 属性，导致落盘复检失败。
  已将这个本轮生成的 App 移至非同步临时目录并清除附加属性；随后 bundle
  和全部 29 个 Mach-O 严格签名复检通过，主程序 SHA-256 未变化。
  没有把未通过验证的副本交付或装到 Desktop。
- 可运行 App：/private/tmp/okvideomac-epg-acceptance/OKVideoMac.app（约 173 MiB）。
  临时目录可能被系统清理；持久保存的候选 DMG 位于下面的验收目录。
- 持久验收目录：build/EPGAcceptance-20260910。
  其中 OKVideoMac-0.6.1.dmg 为本地候选（约 71 MiB），不是正式公开 DMG；
  ZIP 约 64 MiB，SourceRelease 为 exact-source 资料，Logs 为完整验证日志，
  EPG_ACCEPTANCE_PROVENANCE.json 保存基线、快照和逐文件 SHA-256。
- 主程序 SHA-256：c3469045daef2d11eb87051e2e0553e1f0b862d91576fdfaf0fd5f206a063dee。
- DMG SHA-256：bee032112bde85a7757e9c12a816e36c74df5edd29650c518df4ab68d5e56c0a。
- ZIP SHA-256：e006c98f65df91b25aa5f8fb277bec5a1fa02192e06ba3b5e3986c0e2b5342ee。
- 未自动启动候选进入生产账号环境；真实界面、音画、滚动和睡眠体验交由用户人工验收。

## 6. 人工门禁与明确不做

人工步骤见 EPG_MANUAL_ACCEPTANCE.md。必须由用户验证 M3U/XMLTV、Native
真实目录/播放/NowNext、快速换台、无 EPG、Provider/账号切换、断网与睡眠恢复。

不实现 Full Guide、Catch-up、大 XMLTV SQLite 流式存储、播放器核心改造、
全局 LiveChannel.id 迁移、退出后系统后台刷新。
真实 Provider 的私有方言和未携带可解释时区的数据不做臆测兼容。
此轮既不执行也不授权 7B；人工通过后仍需明确批准正式打包/安装/发布。
