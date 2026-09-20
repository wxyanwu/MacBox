# 跳过片头片尾：源码调研与 OKVideoMac 开发方案

调研日期：2026-09-19。第一版已按本文收紧后的方案完成实现，并通过自动化测试；真实资源站的手动回归仍应按第 9 节执行。

## 实施状态（2026-09-19）

- 已实现按“配置 + 站点 + 影片 + 线路”保存的整条线路规则，以及单集逐字段覆盖。
- 已实现片头绝对位置、片尾剩余时长、片头与续播合并为一次起播定位。
- 已实现播放会话内的片头/片尾临时抑制、片尾 5 秒提示、立即跳过和本集不跳。
- 已将片尾触发、EOF 与原自动连播收敛到同一个切集入口，并按播放会话去重。
- 规则与观看历史分开保存；清除观看记录不会删除规则。便携备份格式已升级并向后兼容旧备份。
- 播放设置已提供当前位置标记、±1 秒调整、开关、清除，以及“应用于本线路全部集数”。
- 自动化验证：OKVideoKit 857 个通过、10 个跳过、0 失败；OKVideoMac 894 个通过、8 个跳过、0 失败。

## 1. 结论与推荐

建议为 OKVideoMac 实现“手动标记时间、按剧与线路记忆、自动跳过”的第一版：

- 片头保存“片头结束位置”；片尾保存“距离全片结束还剩多少秒”。
- 默认作用于当前配置、站点、影片和播放线路下的全部集数；支持单集覆盖。
- 在播放设置中编辑时长，也能用当前播放位置一键标记。
- 片头兼容历史续播；片尾复用自动下一集流程，并提供 5 秒倒计时和“本集不跳”。
- 不同线路、不同站点不自动复制规则。显式复制时先展示目标范围。
- 第一版使用本地规则，用户未设置时不跳过。内容识别、在线时间库、跨源自动匹配列为后续独立阶段。

FongMi 已验证了这套基础模型的可行性。OKVideoMac 需要在此基础上处理请求归属、跳转确认、自动连播去重、历史完成状态和线路身份。

## 2. 调研版本与证据边界

| 对象 | 本次确认的版本 | 源码可见范围 |
| --- | --- | --- |
| FongMi/TV | 默认分支 `fongmi`，提交 `4afc4473e22a7ed3d98ee12233e0c2a490061000`，2026-09-08；`app/build.gradle` 为 5.6.3 / 563 | Android 客户端及共用播放逻辑 |
| FongMi/Release | 提交 `f649a86a667432ba38a050c7304beda6d6986511`；电视版和手机版更新元数据均为 5.6.3 / 563 | 发布说明、更新元数据及 APK |
| CatPawApp/CatPawOpen | 默认分支 `main`，提交 `b956aedabe5f624f1e96c8d21c8866617a0f71c1` | README、Node.js 工程和构建工作流 |
| CatPawOpen 发布页 | `beta` 预发布，附件标记为 `open_2.0.3_beta4` | iOS、Windows、HarmonyOS 二进制；没有客户端源码附件 |

“FongMi 最新版”在本文指调研当日官方默认分支和官方发布元数据共同标记的 5.6.3。默认分支不是一个经过本次 APK 二进制溯源验证的发布标签，不能据版本号相同推断构建字节完全一致。

CatPawOpen 的 beta 是可更新的发布条目：GitHub 创建时间是 2025-01-15，但正文有 2025-01-18 Windows/iOS Beta4 和 2025-11-25 HarmonyOS 更新记录，不能把条目创建时间当作全部附件的实际发布日期。

证据：[FongMi 源码提交](https://github.com/FongMi/TV/commit/4afc4473e22a7ed3d98ee12233e0c2a490061000)、[构建版本](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/build.gradle#L22-L23)、[电视版发布元数据](https://github.com/FongMi/Release/blob/f649a86a667432ba38a050c7304beda6d6986511/apk/leanback.json)、[手机版发布元数据](https://github.com/FongMi/Release/blob/f649a86a667432ba38a050c7304beda6d6986511/apk/mobile.json)、[CatPawOpen 源码树](https://github.com/CatPawApp/CatPawOpen/tree/b956aedabe5f624f1e96c8d21c8866617a0f71c1)、[CatPawOpen 发布页](https://github.com/CatPawApp/CatPawOpen/releases/tag/beta)。

## 3. FongMi 怎么实现

### 3.1 时间模型与交互

`History` 持有 `opening`、`ending`、`position`、`duration`，单位为毫秒。未设置使用 `C.TIME_UNSET`，显式清除设置为 0。

- 点片头：记录当前播放位置。例如看到正片开始时为 01:30，记录 90,000 毫秒。
- 点片尾：记录 `duration - position`。例如 45 分钟视频在 43:30 进入片尾，保存的是 90 秒，而不是 43:30。
- 电视版有 ±1 秒微调与清除；手机版提供标记及长按清除。
- 当前点标记有范围检查：全长不足 15 分钟，允许头尾最多 3 分钟；不足 30 分钟为 6 分钟；其余为 10 分钟。

这里的范围检查属于“用当前位置设置”的入口，不能据此声称所有微调入口都有同样的上限验证。

证据：[History 时间字段](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/bean/History.java#L49-L74)、[电视版设置操作](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/leanback/java/com/fongmi/android/tv/ui/activity/VideoActivity.java#L947-L993)、[手机版设置操作](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/mobile/java/com/fongmi/android/tv/ui/activity/VideoActivity.java#L1026-L1062)、[入口验证](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/player/PlayerManager.java#L218-L224)、[分段上限](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/Constant.java#L21-L25)。

### 3.2 跳片头：设置起播位置

`VodHistoryPolicy.startPositionMs()` 的语义为：

```text
起播位置 = max(片头结束位置, 已保存的播放位置)
```

这可以同时满足下一集跳片头和中途续播。切到不同集时 `updateEpisode()` 会清除旧集的播放位置和总时长，保留片头片尾设置。下一集预加载也把片头位置纳入起播计算。

因此，核对到的片头实现是“起播位置策略”，而不是播放期间持续检测画面或音频；不能把它描述成自动识别片头。

证据：[续播与起播策略](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/playback/vod/VodHistoryPolicy.java#L72-L101)、[预加载位置](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/playback/vod/VodPreloader.java#L93-L98)。

### 3.3 跳片尾：提前切换下一集

`Clock` 每秒回调。Activity 先检查播放器归属、点播模式、非负位置和有效总时长，再交给 `VodPlaybackController.onTimeChanged()`：

```text
片尾时长 > 0 且 播放位置 + 片尾时长 >= 总时长
    → nextEpisode(false)
```

这里 `false` 对应是否提示没有下一集，不是“禁止自动切集”。相邻集逻辑也考虑反向播放；没有可切换的集数时不会凭空生成下一集。

这是直接提前切集，不需要先 seek 到文件末尾再等 EOF。核对到的这条调用链没有 5 秒撤销倒计时；本文建议的倒计时是 OKVideoMac 的产品设计。

证据：[Clock](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/utils/Clock.java#L45-L59)、[上层有效性检查](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/leanback/java/com/fongmi/android/tv/ui/activity/VideoActivity.java#L1252-L1259)、[片尾条件与相邻集切换](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/playback/vod/VodPlaybackController.java#L273-L319)。

### 3.4 规则跟随历史，并有同名迁移逻辑

设置保存在 Room 的 `History` 实体；同一影片切集会继续使用规则。保存时存在按同名影片合并历史并复制头尾设置的逻辑，其中 `shouldMerge()` 对双方有效总时长施加相差不超过 10 分钟的条件。

另有 `findEpisode()` 按同名历史与匹配集名恢复并复制设置的路径，它不经过上述时长门槛。因此不能概括成“所有跨源继承都经过 10 分钟验证”。

值得借鉴的是设置可随影片记忆；不建议照搬同名自动迁移。不同剪辑、同名翻拍、不同季或不同线路的片头片尾可能不同。

无痕模式下 `VodHistoryPolicy` 不写历史。普通进度保存中有约 5 秒的调度节流，退出还有保存路径。

证据：[历史保存与无痕](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/playback/vod/VodHistoryPolicy.java#L36-L69)、[合并条件及复制](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/bean/History.java#L297-L314)、[同名恢复路径](https://github.com/FongMi/TV/blob/4afc4473e22a7ed3d98ee12233e0c2a490061000/app/src/main/java/com/fongmi/android/tv/bean/History.java#L337-L391)。

## 4. CatPawOpen 能确认什么

本次检查了官方仓库完整递归文件树、唯一公开分支 `main` 和发布附件。公开内容中没有 Flutter 客户端常见的 `lib/`、`pubspec.yaml`，也没有播放器控制器、头尾设置界面或对应客户端持久化模型。

Node 工程说明其产物供 App 内嵌 Node 运行时使用。以 `ffm3u8.js` 为例，`play()` 返回媒体 URL、解析标识及请求头，并可调用 Dart 侧嗅探；该公开代码没有片头片尾决策字段或执行逻辑。

因此，能下的结论是：**官方公开仓库不足以核实 CatPawOpen 客户端如何跳过片头片尾**。这不等于断言 App 没有此功能，也不等于确认它采用与 FongMi 相同的算法。

如果后续拿到实际客户端源码，可以补充对照；仅有 App 操作测试只能确认外在行为，不能证明内部实现。当前方案不依赖获取这部分源码。

证据：[锁定的公开源码树](https://github.com/CatPawApp/CatPawOpen/tree/b956aedabe5f624f1e96c8d21c8866617a0f71c1)、[Node 工程说明](https://github.com/CatPawApp/CatPawOpen/blob/b956aedabe5f624f1e96c8d21c8866617a0f71c1/nodejs/readme.md)、[play 返回内容](https://github.com/CatPawApp/CatPawOpen/blob/b956aedabe5f624f1e96c8d21c8866617a0f71c1/nodejs/src/spider/video/ffm3u8.js#L159-L191)。

## 5. 当前 OKVideoMac 已有的基础与限制

本地基线为工作区实际文件，HEAD 为 `14dd3a584f49bdb67a5b7edd25c9980f77f480e2`，包含既有未提交修改。以下行号是调研时位置，实施时应以符号名重新定位。

| 现有位置 | 已有能力 | 接入意义 |
| --- | --- | --- |
| `AppState.swift`，`loadResolvedPlayback`，约 18780 行 | 查历史，计算 startPosition，传入播放器加载 | 合并片头与续播，保持启动和资源租约流程 |
| `AppState.swift`，`historyResumePosition`，约 16518 行 | 有效历史续播；距结尾 20 秒内不再续播 | 跳片尾后需要独立完成标记，不能只依靠 20 秒判断 |
| `AppState.swift`，`startPlayerEventLoop`，约 18338 行 | 带 requestID 的播放快照与结束事件 | 复用事件驱动，不再另开轮询定时器 |
| `PlayerSnapshot` | position、duration、isSeeking、isPausedForCache、historyProgressIsReliable | 判断自动跳过的有效时机 |
| `PlaybackEndOrigin` | natural、userSeekBoundary、premature | 必须维持手动拖到结尾不自动连播的约束 |
| `AutomaticEpisodeAdvanceController`，约 4554 行 | 可取消的自动切集任务及归属判断 | 作为自然结束与跳片尾共享的切集通道 |
| `advanceAfterNaturalEnd`，约 18607 行 | 会话检查、下一集选择、保留窗口焦点 | 提取通用切集执行函数，显式传入触发原因 |
| `canSeekPlayback`，约 15637 行 | 排除直播、排除声明不支持 Range 的媒体会话 | 片头自动跳转必须尊重能力限制 |
| `MPVPlayerClient.seekCommand`，约 1405 行 | 使用 `absolute+keyframes` | 跳转可能落在标记之前，长 GOP 不能承诺逐秒精准 |
| `PlayerView.playbackSettingsPanel`，约 1445 行 | 已有自动下一集、倍速等设置 | 新增“片头片尾”设置入口 |
| `SQLiteStore` / `HistoryRecord` / `PortableBackup` | 持久化、配置隔离、便携备份 | 新规则必须明确迁移、删除及备份语义 |

关键实现陷阱：不要在消费 `player.events` 的循环内直接等待一个还要靠后续快照才能完成的 seek / load。现有自动切集控制器已经通过另起可取消任务避免这种阻塞，新增功能要沿用这一点。

## 6. 第一版产品行为

### 6.1 设置界面

播放设置新增“片头片尾”入口，打开独立的轻量面板，避免现有设置页过长。

```text
片头片尾
应用范围：本剧 · 当前线路全部集数 / 仅本集

自动跳过片头           开关
片头结束于             01:30    −1秒 / +1秒
[以当前位置标记]

自动跳过片尾           开关
片尾时长               01:00    −1秒 / +1秒
[从当前位置标记片尾]

[本集暂不自动跳过]   [恢复继承 / 清除本范围设置]
```

- 可输入秒数或 `mm:ss`；较长视频接受 `hh:mm:ss`。非法值在保存前校验。
- “片头结束于”与“片尾时长”必须明确区分，不能都写成含糊的“时间”。
- 显示实际线路名；仅本集编辑应显示规则是否继承自整条线路。
- 开关关闭保留已填时长；“恢复继承”删除单集覆盖；“清除”删除对应范围设置。
- 标记只保存设置，不因一次设置操作立刻切集。当前已处在新设片尾内时只显示按钮；下次正常越过阈值才自动执行。
- 当前时间或时长未知时禁用位置标记；仍可输入待验证的时长。
- 直播隐藏此入口；不支持 seek 的点播禁用自动片头并说明原因。片尾直接下一集不依赖 seek，但仍需可靠总时长和下一集。
- 全屏、窄窗口和 VoiceOver 均能访问；新增文本进入现有本地化资源。

### 6.2 自动行为与优先级

| 场景 | 建议行为 |
| --- | --- |
| 首次使用，未设置任何规则 | 不跳过，不给所有影片默认套用 90 秒 |
| 从头播放且片头设置有效 | 起播到片头结束位置；提示“已跳过片头”，可返回开头 |
| 续播位置已经在正片 | 从续播位置继续 |
| 续播位置落在片头 | 使用片头结束位置 |
| 明确选择“从头完整观看” | 本次忽略片头，保留持久规则 |
| 用户拖回片头或点击返回开头 | 本次不再次自动跳头；仍可手动点“跳过片头” |
| 正常播放进入片尾，自动下一集开启 | 显示“5 秒后播放下一集”，可立即下一集或“本集不跳” |
| 自动下一集关闭 | 显示手动“跳过片尾，播放下一集”；不自动换集 |
| 本集没有下一集 | 继续片尾，不倒计时、不 seek 到结尾、不关窗口 |
| 暂停或缓冲 | 倒计时暂停；恢复播放后继续 |
| 拖进片尾、从历史直接恢复到片尾 | 只显示手动按钮；不因第一帧已满足阈值就自动换集 |
| 用户在本集手动 seek | 取消当前倒计时，本集余下会话不再自动跳片尾；自然 EOF 仍按原连播设置处理 |
| 切换画质或网络恢复 | 保留本集临时禁用和已执行状态，取消旧请求任务；重建请求不当作新一集 |
| 切换线路 | 加载目标线路规则；未知身份时不自动继承 |
| 手动换集、关闭窗口、切配置 | 取消旧任务，旧快照不允许作用到新媒体 |

5 秒是产品交互倒计时，使用单调时钟累计可播放时间，不受系统时间调整影响；倍速只改变媒体播放位置，倒计时仍按实际秒数计算。

### 6.3 数值校验

第一版建议将自动规则限制在头尾各 `min(600 秒, 总时长 × 20%)` 内，并至少保留 30 秒正片。这个阈值是我们的初始产品建议，不是 FongMi 原值，也不是内容识别结果；后续可按真实使用情况调节。

统一在输入、读取存储、合并继承以及每次媒体加载时校验：

- 所有时间必须有限、非负；0 表示不跳。
- 片头结束位置小于 `duration - outroDuration`。
- 总时长未知时仅保存待验证输入，不自动执行；不能用上一集时长代替当前集。
- 新一集明显变短、头尾重叠或不满足保留正片条件时，本次不自动跳并展示可编辑提示，不静默裁剪用户原值。
- 片头和片尾独立有效；单项非法不影响另一项，重叠时两项均不自动执行。
- 时长重估导致阈值突然移动到当前位置之前时，只展示手动操作，不立即自动换集。

## 7. 技术设计

### 7.1 模块划分

```text
PlayerView 设置 / 标记 / 取消
             ↓
PlaybackSkipCoordinator（会话、任务、倒计时、请求归属）
       ↙                  ↘
PlaybackSkipPolicy       PlaybackSkipRuleStore
纯决策与校验             SQLite 持久化与继承
       ↓
已有加载 / seek / 自动下一集执行通道
```

策略放在 `OKVideoCore`，持久化放在 `OKVideoPersistence`，协调器放在 App 层。`AppState` 负责连接，不继续承载全部规则与倒计时细节。

不需要新增 FFmpeg 扫描、Android 桥接指令、Node 插件协议或后台网络服务；本地规则对所有已接入点播提供方共用。

### 7.2 数据模型与作用范围

推荐独立 `playback_skip_rules` 表，不把规则生命周期绑到观看历史：用户清理历史后仍可保留主动设置的规则。

```text
PlaybackSkipRule
  schemaVersion
  configurationID
  siteKey
  videoIdentity
  sourceIdentity
  scope: seriesLine | episode
  episodeIdentity: 空串表示线路规则；单集规则必须有身份
  intro: inherit | disabled | enabled(endSeconds)
  outro: inherit | disabled | enabled(durationSeconds)
  updatedAt
```

唯一键由配置、站点、影片、线路、范围、集身份共同组成。存储使用明确的状态枚举，不能让 `nil` 同时表示关闭和继承；线路基础规则不能继承，缺失等同关闭。Swift 运行时使用秒，避免照搬 FongMi 毫秒产生千倍错误。

逐字段解析优先级：本集临时禁用 > 单集明确值 > 当前线路整剧值 > 关闭。单集只改片头时仍能继承整剧片尾；单集明确关闭则屏蔽父级。

身份处理必须专门审查：当前 `PlaySource.id` 是名称，`PlayEpisode.id` 包含 URL；不能直接把这两个 UI ID 当稳定持久键。优先复用 provider 明确稳定的 identity 与项目现有历史导航身份；没有稳定身份时使用配置/影片作用域内的导航描述，要求唯一匹配，否则仅本次生效。来源全集推导的 identity 也应验证在新增集数后是否稳定，不能因名字叫 stableIdentity 就跳过该测试。

不保存签名媒体 URL、Range 会话地址或临时桥接 token。相同标题不会触发跨站合并。用户显式复制规则到另一线路时重新校验目标身份与时长。

### 7.3 起播与片头

新增纯函数 `resolveStartPosition(resume, intro, intent, duration)`，在经过当前媒体时长验证后，正常起播取有效续播与片头位置较大值。

执行要与现有 `pendingStartPosition` 合并，避免“先续播一次，再跳头一次”：

1. 加载前建立本集规则及播放意图上下文，绑定 requestID；加载时拿不到可靠时长就保留待处理状态。
2. 在原生 file-loaded 后、当前 duration 可用时统一决定一个起播目标。可小范围扩展现有起播参数为启动定位计划，使历史位置和片头共享一次定位；不要绕过启动门控。
3. 若第一次只能完成历史恢复，迟到的片头设置只在仍处于初始定位阶段、尚未有用户操作时使用；进入正常正片后不再迟到跳转。
4. 原生跳转完成后才更新“已应用片头”与可靠进度；失败则本次关闭自动重试并允许正常播放。
5. 媒体不支持 seek 时，不传入片头定位目标。

现有 MPV `absolute+keyframes` 对远程媒体更稳，但目标可能落在片头之前。第一版保持现有定位策略，接受并明确记录关键帧误差；绝不能以“当前位置仍小于片头值”为理由每个快照重试。

如产品验收要求逐秒准确，应增加带意图的 seek 选项，仅在验证安全的本地/直连媒体对片头使用精确 seek；TVBox Range、网盘转发保留原策略。精确定位是单独验证项，不应为头尾功能全局改成 exact。

### 7.4 片尾状态机与切集去重

```text
waitingForReliablePlayback
  → armed（确认从阈值前正常播放）
  → countdown（跨过片尾阈值）
  → advancing（原子认领本集唯一切集资格）
  → completed

任意阶段 → cancelled / disabledForEpisode
```

启动自动倒计时要求：当前点播、正确 requestID、正常 playing、未 seeking、未缓存暂停、进度可靠、有效当前 duration、有效规则、有下一集、自动连播开启、此前在阈值之前自然播放。

倒计时结束必须再次检查条件。规则编辑、用户 seek、切集、切线路、关闭窗口均使旧任务失效。所有 await 前后检查 owner；不要让慢数据库读写在用户已经换剧后执行旧动作。

每个逻辑播放实例保留 `{episodeSessionID, requestID, ruleRevision}`。换画质/恢复会更新 requestID，但继承同集已执行/临时禁用状态；重新选择一集或明确重播建立新的 episodeSessionID。

自然 EOF 和跳片尾共用一次切集认领，提交资格后再发起异步解析。仅靠现有 `schedule()` 取消上一任务不够：重复快照可能反复取消并重启解析，必须在调用 schedule 之前完成幂等检查。

建议将 `advanceAfterNaturalEnd` 的执行主体提取为 `advanceEpisode(trigger:)`，触发原因至少区分 `.naturalEnd`、`.outroSkip` 与手动操作。保持原生 `PlaybackEndOrigin` 含义不变，不把跳片尾伪造为 natural EOF。

倒计时中自然结束：取消倒计时，原生自然结束通过同一认领入口切集。下一集解析失败：只显示一次可重试状态，不因后续快照再次发起跳片尾；保留当前集可继续观看或重播的入口。

### 7.5 观看历史与恢复

当前历史在“距离结束不足 20 秒”时才放弃续播。如果片尾跳过 90 秒，仅保存实际位置，重开历史会回到片尾。因此第一版必须同时设计完成语义。

建议给当前历史增加可选完成元数据：`completionReason`（natural / outroSkipped）、`completedEpisodeIdentity`、`completedAt`。保持实际 `position` 不变，不能为了显示完成而把位置伪造为 duration。

- 在倒计时结束或用户确认跳片尾后保存本集完成状态，再进入下一集流程；取消倒计时不标完成。
- 下一集开始的第一条历史写入必须清除上一集完成元数据，因为当前历史行是按影片/线路维护，不是每集独立行。
- 历史保存任务需带集身份和请求归属，旧任务不能覆盖新一集进度或完成状态。
- 已完成的同集历史不续播到片尾，沿用“重播该集”的语义并应用片头；下一集按钮仍可显式选择，不因打开历史自动连跳。
- 手动返回已完成集正文并持续播放时，清除完成标记，恢复真实续播行为。
- 非可靠进度、seek 中间状态继续受 `historyProgressIsReliable` 与现有 checkpoint 约束。

### 7.6 持久化、无痕、删除与备份

- 数据库增加规则表和完成元数据迁移；版本号按实施时最新 schema 递增，不在当前并行改动上硬编码某个旧版本。
- 修改时保存，播放期间仅读内存快照；无需每秒写规则表。
- 写入失败显示未保存状态或回滚，不让 UI 声称已持久化。
- 无痕模式可读取已有规则，所有规则编辑、临时禁用和完成状态仅在内存生效。
- 清理观看历史保留跳过规则；新增“清除片头片尾设置”管理入口。删除所属配置同时删除规则。
- 当前便携备份只包含配置与历史，不能以为新增表会自动被备份。扩展 `PortableBackup` 载荷，加入当前配置规则和完成元数据。
- 新格式版本向前读取旧备份，旧备份缺少规则即空集；配置导入重新映射 configurationID，按 updatedAt 处理冲突。新版本备份被旧 App 明确拒绝，避免静默丢失设置。
- 配置、历史、规则导入应统一事务，并保留现有导入前安全备份语义。第一版不额外增加在线同步。

## 8. 文件级实施清单

路径均相对于 `OKVideoMac/macOS/OKVideoMac/`，以下新增文件名称是建议。

| 文件 / 模块 | 工作 |
| --- | --- |
| `Packages/OKVideoKit/Sources/OKVideoCore/Playback/PlaybackSkipRule.swift` | 范围、三态覆盖、规范化、规则解析 |
| `.../Playback/PlaybackSkipPolicy.swift` | 数值验证、起播目标、片尾触发纯函数 |
| `Packages/OKVideoKit/Sources/OKVideoPersistence/Database/PlaybackSkipRuleStore.swift` | 规则 CRUD、配置删除与导入合并 |
| `.../Database/SQLiteStore.swift` | schema 迁移、历史完成字段、原子导入 |
| `.../Models/PersistenceModels.swift` | HistoryRecord 可选完成元数据与旧数据解码 |
| `App/PlaybackSkipCoordinator.swift` | 同集会话、倒计时、取消、任务去重 |
| `App/AppState.swift` | 播放入口、快照、用户 seek、换画质、关窗、历史保存接线 |
| `App/PortableBackup.swift` | 新备份格式与兼容旧格式 |
| `Features/Player/PlaybackSkipSettingsView.swift` | 时长输入、位置标记、范围/继承/关闭 |
| `Features/Player/PlayerView.swift` | 设置入口、倒计时、撤销及手动按钮 |
| `Player/MPVPlayerClient.swift` / `OKVideoCore/Player/PlayerClient.swift` | 必要时将启动定位计划与现有定位合并；保留底层 EOF 防护 |
| `Features/Settings/SettingsView.swift` | 清除片头片尾规则的管理入口 |
| `Resources/Localizable.xcstrings` | 本地化及可访问性文案 |
| 核心、持久化与 App 测试 | 边界、迁移、竞态和多来源验收 |

## 9. 实施顺序与工作量

以下为单人熟悉当前项目后的工程估算，不是承诺工期；以已有改动稳定、测试媒体可用为前提。

1. **规则和持久化，约 1–2 天**：身份审查、模型、校验、继承、迁移、备份兼容。
2. **播放器接线，约 2–3 天**：起播合并、片尾状态机、连播去重、历史完成、切画质与恢复。
3. **界面交互，约 1–2 天**：编辑、位置标记、范围、倒计时、取消、可访问性。
4. **真实来源回归与 Release，约 1–2 天**：直连、HLS、Node、TVBox、无 Range、异常恢复及打包安装。

完整第一版估计 5–9 个开发日；TVBox 长 GOP / Range 行为或身份匹配出现缺陷时需要额外时间。阶段应分别可审查，但发布时应包含以下 P0 验收项。

后续第二阶段再做章节候选、来源提供的时间段、冷开场后的区间片头、多段片尾和彩蛋保留。若做内容识别，需另行确定元数据来源或音频/画面匹配方案、成本与准确性指标，不应假设片头总从 0 开始。

## 10. 验收矩阵

| 优先级 | 场景 | 必须满足 |
| --- | --- | --- |
| P0 | 片头 90 秒，续播为空 / 30 秒 / 600 秒 | 逻辑目标分别为 90 / 90 / 600；一次起播定位 |
| P0 | 单集覆盖、单集关闭、恢复继承 | 三种行为可区分，关闭不被父级重新开启 |
| P0 | 总长 2700 秒、片尾 90 秒 | 阈值 2610；正常跨越后一次倒计时；约 2615 时确认切集，受播放状态影响 |
| P0 | 拖到片尾、拖到 EOF、暂停、缓冲 | 无意外自动下一集；倒计时按规则暂停/取消 |
| P0 | 取消跳片尾后继续播放 | 本集不重新倒计时；自然 EOF 仍按原连播设置执行 |
| P0 | 最后一集、自动下一集关闭 | 不自动换集，不跳到文件末尾 |
| P0 | 倒计时与 EOF 同时发生 | 只发起一次下一集解析与加载 |
| P0 | 重复快照、旧 requestID、快速换集、关闭窗口 | 无重复切集、无旧任务控制新视频 |
| P0 | 换画质、网络恢复、下一集失败 | 同集临时状态保留；失败不反复触发 |
| P0 | duration 为 0 / 非有限 / 变化，短集，头尾重叠 | 不误跳，不使用上一集 duration |
| P0 | TVBox 长 GOP、Node Range、seek 失败 | 不追逐目标反复 seek；错误不被判成自然结束 |
| P0 | 不支持 Range 的媒体会话 | 片头不发 seek；片尾仅在可靠时长与下一集具备时可执行 |
| P0 | 跳片尾后重开历史，旧写入晚到 | 不回到已完成片尾，不覆盖新集进度 |
| P0 | 配置隔离、同名剧、线路切换、集数新增 | 无规则串用；身份不可靠则不自动继承 |
| P0 | 老数据库升级、旧备份导入、新备份往返、写入失败 | 无旧历史丢失；规则和完成状态一致 |
| P0 | 无痕、清历史、删配置 | 无痕不落盘；历史清理保留规则；配置删除清规则 |
| P1 | 窄窗口、全屏、VoiceOver、中文/英文 | 控件可达、布局不遮挡、时长语义明确 |
| P1 | 性能 | 每快照常数级判断，零额外网络请求，不按秒访问规则数据库 |

测试组合：策略单测使用纯输入；协调器测试使用可控时钟与伪 PlayerClient，精确重现事件竞态；数据库测试覆盖真实升级/导入；实际播放采用本地确定性素材加现有直连、Node 和 TVBox 验收来源。

关键帧定位误差与纯策略目标分别验收。不要使用“必须距目标小于 1 秒”作为所有 TVBox seek 的成功条件，现有代码已经说明这种条件会误判长 GOP。

## 11. 发布要求与本次交付范围

实施完成后运行适用的 Core/Persistence/App 测试及真实播放回归，再按项目 `AGENTS.md` 使用 `Scripts/package-app.sh` 构建并校验 Release 包。只有通过校验的 Release 才能替换用户桌面的 `OKVideoMac.app`；打包或包验证失败不得替换。

本次只提交这份源码调研与开发方案，没有修改播放器实现，没有构建或替换桌面 App，也未把未来验收项目描述成已通过。
