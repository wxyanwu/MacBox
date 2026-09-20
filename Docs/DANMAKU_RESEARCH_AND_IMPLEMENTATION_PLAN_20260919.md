# 弹幕源码调研与 OKVideoMac 完整开发方案

日期：2026-09-19。状态：仅调研与方案，未实现弹幕、未构建或替换 App。当前工作分支 `codex/epg-7a1-progress-ui`。下文明确区分上游已核实行为和 OKVideoMac 设计建议。

## 1. 调研结论与证据边界

FongMi 官方 TV 默认分支最新提交为 `4afc4473e22a7ed3d98ee12233e0c2a490061000`（2026-09-08），官方电视版发布元数据为 5.6.3 / 563。版本号相同不等于本次已完成 APK 与源码的二进制溯源。

CatPawApp/CatPawOpen 默认分支最新提交为 `b956aedabe5f624f1e96c8d21c8866617a0f71c1`（2025-01-17）。本次检查未截断的完整递归目录树及全部公开文件：只有 Node 工程、README 和构建流程，没有客户端播放器、弹幕排布/绘制实现，也没有检出 `danmaku`、`danmu` 或“弹幕”。这只能证明公开源码未提供该实现，不能据此认定发行客户端不支持弹幕。

CatPawOpen 当前公开 beta 附件名为 open_2.0.3_beta4，包含 iOS、Windows、HarmonyOS；发布正文分别列出 2025-01-18 和 2025-11-25 的更新。不能用 beta 条目的初次发布时间代表所有附件版本。

证据：

- [FongMi 固定提交](https://github.com/FongMi/TV/tree/4afc4473e22a7ed3d98ee12233e0c2a490061000)
- [FongMi 官方版本元数据](https://github.com/FongMi/Release/blob/fongmi/apk/leanback.json)
- [CatPawOpen 固定提交完整树](https://github.com/CatPawApp/CatPawOpen/tree/b956aedabe5f624f1e96c8d21c8866617a0f71c1)
- [CatPawOpen Node 工程说明](https://github.com/CatPawApp/CatPawOpen/blob/b956aedabe5f624f1e96c8d21c8866617a0f71c1/nodejs/readme.md)
- [CatPawOpen 发布记录](https://github.com/CatPawApp/CatPawOpen/releases/tag/beta)

## 2. FongMi 实际怎么做

### 2.1 来源描述与评论内容是两层数据

`Danmaku` 是来源对象，字段为 `name`、`url`，并不是单条评论。`DanmakuAdapter` 接受 URL 字符串、JSON 数组字符串、数组对象；空 URL 被过滤。`PlaySpec` 初始化时选择第一条来源，后续可切换或取消选择。

示例：

```json
{"danmaku":[{"name":"本集弹幕","url":"https://example.org/episode.xml"}]}
```

来源：[来源对象](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/bean/Danmaku.java)、[兼容解码](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/gson/DanmakuAdapter.java)、[选择状态](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/player/media/PlaySpec.java)。

### 2.2 自动搜索不是画面识别

`DanmakuApi` 使用片名和集名搜索。接口 URL 含 `{name}` 或 `{episode}` 时，替换 URL 编码后的值发 GET；否则将 `name`、`episode` 放入请求体发 POST。搜索前将繁体文字转换为简体。

返回值解析为来源列表。自动搜索重载选择第一条结果；手动搜索接口允许展示整个列表。用递增请求 ID 和请求取消抵御旧搜索回调。

接口优先采用用户设置，否则采用配置中的 `danmaku`。自动搜索要求允许加载、开启自动搜索、有有效接口；`VodPlaybackMedia` 还检查站点的弹幕开关。若开启“Spider 优先”且播放结果已有弹幕，搜索结果只加入候选；否则将搜索结果设为当前来源。

来源：[搜索协议](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/api/DanmakuApi.java)、[选源优先级](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/playback/vod/VodPlaybackMedia.java)。

### 2.3 文件、解析和显示

弹幕面板支持选择来源、手动搜索、选择文本文件和调整显示参数。主仓库还保留 `DanmakuData`：读取逗号分隔参数中的时间、类型、字号、颜色，将秒转为毫秒，并处理文本实体与繁简转换。这是 Bilibili 风格 XML 数据字段的证据，但不能仅凭该类仍存在就断言它是当前唯一解析入口。

当前 `PlayerManager` 导入 `androidx.media3.ui.danmaku.DanmakuConfig`，通过 `onDanmakuSourceChanged`、`onDanmakuConfigChanged`、`onDanmakuEnabledChanged`、`onDanmakuSent` 回调传递 URI、外观、开关和文本。不能把旧版本的 DanmakuFlameMaster 结论直接套到当前提交；也不能仅凭包名把这套弹幕功能说成 Google 官方 Media3 标配。

本次在 TV 主仓库未找到该 Media3 弹幕组件的绘制/轨道调度源码，因此不对其具体碰撞算法、帧率、线程实现或完整格式支持作确定描述。回调中的“发送文本”也不能证明存在向弹幕服务发帖的网络接口。

来源：[文件与选源 UI](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/ui/dialog/DanmakuDialog.java)、[数据字段解析](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/bean/DanmakuData.java)、[播放器回调](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/player/PlayerManager.java)。

### 2.4 设置值得借鉴，但不必全部移植

FongMi 分开保存加载、自动搜索、显示开关，并提供字号、透明度、字体、描边、颜色、时间偏移、滚动/固定停留时长、数量上限、显示区域和各类型开关。源码默认滚动时长 8 秒、固定时长 5 秒、屏幕数量上限 150、滚动区域 50%；这是设置默认值，不是本次测得的性能保证。

来源：[DanmakuSetting](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/setting/DanmakuSetting.java)。

## 3. OKVideoMac 当前基础与缺口

- `ConfigurationModels.swift` 已有配置级 `danmaku: String?`。
- `UpstreamResponseDecoder.swift` 保留 `danmaku` / `danmu` 为 `SitePlaybackResult.danmaku: JSONValue?`。
- `NodeBundleRuntimeService.swift` 已将部分 Node 配置的 `video.danmuSearchUrl` 转为根配置 `danmaku`；这是本项目兼容逻辑，不能反推 CatPawOpen 客户端源码。
- `ResolvedMedia` 暂无弹幕来源字段；需要从成功的候选结果把弹幕描述传到会话，避免媒体解析后丢失。
- `PlayerSnapshot` 已有位置、倍速、暂停/缓冲、seek 状态；`PlayerEvent` 已有 requestID 和媒体释放事件，可作为同步及请求归属基础。
- `PlayerView` 已有播放控制、字幕面板和片尾提示；新增绘制层需要与实际视频矩形、MPV 原生视图、SwiftUI 交互层一起验证。

弹幕与视频文件格式无直接绑定。MP4/HLS、JS/Dex/Node/Xtream 点播可以共用显示核心，但各 provider 是否保留弹幕字段、是否需要会话代理/请求头，必须分别验证。支持播放某种源不等于该源天然有弹幕。

## 4. 推荐第一版范围

建议实现“本地 XML + 源提供弹幕 + 可配置接口的手动搜索”，然后再开启保守的自动匹配。

第一版支持普通右向左滚动、顶部固定、底部固定；高级定位、脚本、彩色动画、实时直播聊天室、发送评论不纳入第一版。未知模式忽略并计数，绝不执行内容中的脚本。

来源选择顺序：本集明确手动选择 > 当前播放源提供 > 用户主动搜索选择。外部自动搜索单独默认关闭；用户启用后，先选源提供，再搜索，存在歧义时展示候选。只返回 `name/url` 的接口通常不足以自动验证季、集和剪辑版本，不能照搬“第一条直接用”。

本地导入不需要联网。没有接口时仍能使用本地文件或源返回弹幕；没有弹幕时视频正常播放。

## 5. 模块与接口设计

```text
上游播放结果 / 本地文件 / 搜索接口
                 ↓
DanmakuSourceResolver → DanmakuRepository（下载、缓存、取消）
                 ↓
DanmakuParser → DanmakuTimeline（排序、时间索引）
                 ↓
DanmakuSessionCoordinator ← 已有 MPV 播放事件
                 ↓
DanmakuScheduler → DanmakuOverlayView
```

- `OKVideoCore/Danmaku`：来源规范化、XML 解析、评论模型、时间索引、过滤和排布纯逻辑。
- `OKVideoPersistence`：偏好、选择绑定与时间校准，独立于 History。
- `App/DanmakuSessionCoordinator.swift`：负责请求归属、状态和取消；AppState 只接线。
- `Features/Player/Danmaku`：控制面板与绘制层。高频刷新隔离在此，不发布全局 AppState 变化。

建议模型：

```text
DanmakuComment { id, timeSeconds, mode, text, rgb, originalFontSize }
DanmakuSource { id, name, formatHint, runtimeLocator }
DanmakuTrack { sourceID, commentsSortedByTime, contentDigest }
DanmakuBinding {
  configurationID, siteID, contentID, lineID, episodeID,
  providerID?, remoteEpisodeID?, timeOffsetSeconds, updatedAt
}
DanmakuPreferences {
  enabled, autoSearch, opacity, textScale, areaRatio,
  density, showScrolling, showTop, showBottom
}
```

来源 URL、请求头、代理租约放在 runtimeLocator 中；禁止把签名播放链接、Cookie、短期代理地址作为持久 identity。原始 URL 与凭据不进入日志/备份。用户自定义搜索接口若含密钥，沿用项目敏感配置策略。

同一集换清晰度可保留已选数据；跨线路默认重新匹配并隔离偏移。系列远程 ID 可作为搜索提示，单集映射仍需确认，避免特别篇/倒序列表错配。清历史不清绑定；清配置删除所属绑定；无痕会话不写绑定/缓存。备份包含可恢复的稳定映射与偏好，不备份弹幕正文缓存。

## 6. 获取与格式兼容

### 6.1 来源规范化

支持 URL 字符串、数组对象、JSON 数组字符串，与 FongMi 可见输入一致。单对象等额外形态只有实际 fixture 证明后才作为明确扩展支持。配置级 `danmaku` 是搜索入口，播放结果级 `danmaku` 是来源列表，不要把两者混成同一类型。

直连、解析器、嗅探、缓存播放和重试路径都要保留成功候选对应的弹幕信息；失败候选不能污染最终会话。建议扩展 ResolvedMedia 的来源描述，凭据通过会话 resolver 传递。

### 6.2 下载与会话代理

后台异步下载，弹幕失败不阻塞视频起播。起步建议单请求 10 秒、20 MiB 解压后正文上限、10 万条上限、单条 500 字符；这些是待压测的产品预算，不是已验收指标。流式读取并同时限制压缩/解压体积，不依赖 Content-Length。错误原因轻提示，支持重试。

默认不跨域复用视频 Authorization/Cookie；来源明确要求的头按 origin 限定，重定向重新验证。Node/Dex 本机代理必须绑定活跃 provider 会话和取消信号，不能因为 URL 是 localhost 就全放行，也不能全拒绝导致合法来源不可用。

缓存按正文 digest、provider/配置隔离并设 LRU 容量（初始 100 MiB）；有效期与 ETag/Last-Modified 配合。关闭加载或换集取消在途任务，过期请求即使成功也不更新 UI。

### 6.3 解析

先支持 Bilibili 风格 XML：`<d p="时间,模式,字号,十进制颜色,...">文本</d>`。采用 XMLParser 的事件式解析，禁用外部实体和外部 DTD，不用正则当完整 XML 解析器。文本只按普通文字绘制，不解释 HTML/ASS 控制序列。

JSON 没有统一弹幕标准。第一版只内置有 fixture 的适配器；不要宣称所有 `danmu` JSON 都能直接兼容。排序同时间以原始序号稳定决策；只做精确重复项去重，不把不同时间相同文字全部合并。

## 7. 时间同步：P0

播放器是唯一媒体时间权威。显示刷新用单调时钟插值：

```text
mediaNow = anchorMediaTime + elapsedMonotonic × playbackRate
commentClock = mediaNow - offset
```

约定正 offset 为“延后”：原时间 10 秒、offset +2 秒，在视频 12 秒出现。UI 用“提前 0.5 秒 / 延后 0.5 秒”，避免正负号语义混乱。

插值仅在正常播放且快照新鲜时成立；暂停、缓存暂停、seek、休眠、失去当前请求归属时冻结或清空。快照长时间不更新时停止外推并重新校准，不能让弹幕先跑几十秒。显示帧循环不向 MPV 每帧同步查询。

第一版将出现时间和运动统一使用媒体时间：2 倍速时运动与停留同步加速，行为容易复现。以后如增加独立弹幕速度，再拆分运动时钟，并单独验收快进与重建语义。

seek 立即清空活动弹幕，落点确认后用二分索引定位，不补发跳过区间。第一版从新落点之后开始出弹幕，最多容许一个显示帧的边界容差，不重播整屏历史。倒退可以再次看到该时间段评论。片头跳过自然沿用此逻辑；片尾切集在新 generation 下清空旧轨道。

每个任务绑定 `(playbackSessionID, requestID, sourceGeneration)`。换源、换集、重试、取消搜索时检查所有适用归属；不能只用取消任务代替回调归属检查。

## 8. 渲染与轨道排布

推荐先做独立 AppKit NSView + Core Text/Core Graphics 原型，嵌入现有播放器覆盖层；SwiftUI 负责面板。Canvas 可作为对照实现，但不要为每条弹幕建一个带隐式动画的 SwiftUI Text。具体方案必须通过 macOS 12、MPV OpenGL 视图、全屏及多显示器实测后选定。

绘制层位于视频上方、控制条/加载错误/片尾提示下方，鼠标穿透，不抢拖动、双击和滚轮。按实际视频可见矩形裁剪，包含黑边、缩放、旋转、Retina 与窗口尺寸变化。默认只用上半屏；底部固定弹幕默认关闭，给 MPV 内部字幕预留空间。无法可靠读出实际字幕矩形时只提供固定安全区，不宣称能智能避让字幕或人物。

按显示器刷新信号调度，起步最高 60 FPS，性能不足退到 30 FPS；macOS 12 兼容路径可使用 CVDisplayLink，回调只投递合并后的绘制请求，不能直接跨线程操作 NSView。关闭、最小化、无可见活动项且下一项未到时停止持续绘制；暂停后只保留静态画面。

轨道算法：每条文字先测宽，再寻找安全轨道。匀速右向左时 `speed = (viewportWidth + textWidth) / lifetime`。新弹幕进入时，前一条必须完全进入并有最小间距；若后一条更快，还需验证追赶时间不短于前条剩余可见时间。固定弹幕单独维护顶部/底部占用。无可用轨道时丢弃本条显示，不排队延后，以免时间失真。

字号、窗口宽度改变时重建轨道；活动数量、待绘制队列、字形缓存都有限额。缓存按文字+字体+尺寸+描边+屏幕缩放因子索引。第一版密度可设低/中/高，对应数量预算建议 30/60/100，同时受轨道碰撞限制。

技术参考：[Apple Canvas](https://developer.apple.com/documentation/swiftui/canvas)、[Apple CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink)。以上渲染架构和数字均为本项目建议，不是上游性能结论。

## 9. UI 与匹配体验

播放器工具栏增加“弹幕”开关及轻量面板：

```text
弹幕                  开 / 关
来源                  本集弹幕 ▾
搜索弹幕…             导入弹幕文件…
字号                  小 / 中 / 大
不透明度              75%
显示区域              上半屏
密度                  中
时间校准              提前 0.5 秒 / 0.0 秒 / 延后 0.5 秒
```

高级设置再放类型过滤、自动搜索、接口配置。搜索默认填当前剧名、季/集线索，用户能修改；候选显示提供方、标题、季集、时长（接口有才显示），匹配错可立即重选。无结果、加载中、解析失败、已关闭是不同状态；不弹阻塞对话框。

首次主动开启外部自动搜索时说明会向所选服务发送片名/集名，并保存用户选择；不自动上传媒体 URL、文件或 hash。内置某家官方服务适配器前须单独核实当时的接口契约、鉴权和限流，不能把非官方代理协议当官方 API。

## 10. 开发顺序与交付门槛

1. **规则与数据层**：来源规范化、XML parser、时间索引、假时钟与轨道调度测试。覆盖非法 XML、非有限时间、超限、同时间稳定顺序。
2. **本地端到端原型**：本地 XML + MPV + 独立绘制层，先验收暂停/倍速/seek/窗口变化与字幕共存。该阶段证明渲染选型。
3. **上游来源接线**：将 successful candidate 的来源带入最终会话；跑直连、解析、JS、Dex、Node、Xtream fixture，验证有/无字段和代理过期。
4. **手动搜索与持久化**：实现 FongMi 可见接口契约、候选选择、单集偏移、缓存/无痕/备份。
5. **可选自动匹配**：只在身份可靠或已确认映射时自动；模糊标题、多季、特别篇坚持候选选择。
6. **Release 验收**：全量相关测试后，通过 package-app.sh 构建验证 Release，再按项目要求安装桌面；检查 nohidden，避免暂存目录隐藏属性残留。

建议验收矩阵：

| 维度 | 必测项 |
| --- | --- |
| 生命周期 | 连续快速换集、换弹幕源、同集重试、关闭窗口、旧请求迟到、休眠恢复 |
| 时间 | 从头、历史续播、片头跳过、片尾自动下一集、前后 seek、0.5/1/1.5/2 倍速、暂停及缓冲 |
| 布局 | 16:9/4:3/竖屏、全屏、窄窗口、Retina、双屏移动、字幕同时开启、控制条可操作 |
| 内容 | 中英混排、emoji、组合字符、长文字、颜色/字号异常、乱码、10 万条、大量同秒评论 |
| 网络 | 404、超时、重定向、跨域头部、gzip 超限、Node/Dex 代理失效、下载取消 |
| 持久化 | 单集校准、线路隔离、清历史保留绑定、清配置删除绑定、旧备份兼容、无痕 |

建议初始性能门槛：在明确记录机型、macOS、分辨率、视频与弹幕 fixture 的条件下，测关闭/开启弹幕的差值；中密度绘制处理 p95 目标 <4ms、增加的内存目标 <80MiB、连播 30 分钟无持续增长，视频掉帧相对基线无明显回退。未实测前不写“已达到”。热负载下降级应先减密度，再降刷新率。

按单名熟悉项目的开发者估计，核心与本地同步原型约 3–5 个工作日，上游接入/搜索/持久化约 3–5 日，回归与 Release 验收约 2–4 日，总体 8–14 日作为排期参考；远端 API 契约和 macOS 12 渲染验证可能改变估计。

## 11. 最终建议

保留 FongMi 的来源模型、可配置搜索、手动修正和独立显示参数；对自动首条匹配采取更保守策略。客户端排布与同步由 OKVideoMac 原生实现，不要求 Node 或 Android 负责每帧绘制。先把“有弹幕文件就能稳定同步显示”做扎实，再扩大匹配服务，才能让功能覆盖更多源而不伤害已有播放稳定性。

## 12. 0.7.0 实现结果

本轮已按 1A → 1B → 1C 完成首个可发布闭环：

- `ResolvedMedia` 传递完整 `DanmakuPlaybackContext`，TVBox、CatPawOpen 与 Xtream 只负责提供内容、分集、版本身份和来源/搜索能力，下载、解析、时钟、排布、绘制与绑定共用一套 DanmakuCore。
- 播放结果兼容顶层 `danmaku` / `danmu` 与 CatPaw 常见的 `extra.danmaku` / `extra.danmu`；单来源自动加载、唯一 preferred 自动加载，多来源不明确时等待用户选择。
- CatPaw `danmuPush` 绑定精确的播放 request ID 和 generation；换集或换请求后的迟到消息无法写入新会话。源播放结果拥有更高优先级。
- Bilibili XML 使用事件式 parser，限制 32 MiB、10 万条和单条长度；运行期 URL、请求头、Cookie、本机代理 generation/lease 由不可编码类型持有。
- AppKit Overlay 以 MPV 快照为媒体时间权威，在内部 30 FPS 插值和绘制；暂停、缓存、seek、倍速、窗口尺寸变化、时间偏移和弹幕源替换会重新锚定或重建轨道，不向全局 AppState 发布逐帧状态。
- 用户可开关弹幕、选择来源、导入本地 XML、使用配置级或自填 CatPaw 兼容服务搜索、调节字号/透明度/显示区域/密度，并按 0.5 秒校准。
- 绑定按 configuration + site + content + episode + edition 保存，观看历史清理不会删除；配置删除会删除所属绑定。便携备份 schema 升至 3，旧备份仍可读，新备份包含稳定绑定与偏移，但不包含运行期 locator。
- 自动外部匹配仍保持关闭并后置。当前 Release 不会在用户未搜索或未选择的情况下把片名发送给外部弹幕服务。

发布前自动验证结果：Danmaku 专项 12/12；OKVideoKit 869 通过、10 跳过、0 失败；macOS 应用测试 886 通过、8 跳过、0 失败。真实来源的长时播放、Retina/双屏和不同剪辑版本仍属于人工验收矩阵，不能由单元测试替代。
