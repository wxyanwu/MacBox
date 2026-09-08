# OKVideoMac Native Xtream Provider 兼容性详细审计报告

> 历史审计记录：以下结论描述 2026-09-08 当时的阶段，不能替代 0.6.0 发布验收。共享播放器所有权及 Native Live 网络保护已实施；`info: []` 缺陷已由 0.6.0 的 empty-VOD 回归修复。当前能力见 [兼容矩阵](../OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

审计日期：2026-09-08（Asia/Shanghai）

审计对象：当前工作区及已安装本地 Release `OKVideoMac 0.5.0 (99)`

分支：`codex/full-app-localization`

HEAD：`475845727b41b2688fb7a7a0a2ce74afe340a570`

结论性质：本地 RC 前兼容性审计，不是正式发布批准

## 1. 执行摘要

当前 Native Xtream Provider 已经形成一条独立、原生、凭据隔离的 Xtream 链路，覆盖：

- 账号认证和状态判定；
- Movie 分类、列表、详情和播放；
- Series 分类、列表、详情、季/集和连续播放；
- Movie + Series 本地聚合搜索；
- Basic Live 分类、频道、搜索、收藏/隐藏、刷新、TS/HLS 播放目标和同频道有限恢复；
- `container_extension` 到标准 Xtream 播放 URL，再到 libmpv、VideoToolbox、seek 和 EOF 的完整路径。

就已经验证的标准 Xtream/XUI 风格 API 而言，Movies、Series、Search 和 Basic Live 的主路径兼容性较高。实现也对 Xtream-compatible 常见的字符串/数字混用、缺少非关键字段、Series 两种季集结构、空目录返回 `null`/`{}` 等情况做了明确兼容。

但当前不能宣称“兼容所有 Xtream-compatible 源”，原因有三类：

1. **已确认的核心缺陷**：`get_vod_info` 返回 `{"info":[]}` 时会被判为 malformed JSON，无法使用列表中已经存在的 `stream_id` 和 `container_extension` 进入详情/播放。该问题是 Movies + Series + Search 进入正式 0.6.0 RC 前的 blocker。
2. **有意不支持的协议扩展**：`direct_source`、Xtream EPG、catch-up/timeshift、Live 导出、多 Xtream Live 来源聚合均不在当前 Basic Live 范围。
3. **验证覆盖仍有限**：完整黑盒主要基于 IPTVnator Xtream Mock 和本地真实媒体，没有覆盖多家线上 Xtream/XUI 分支、WAF/CDN、跨域 API 跳转、自签名 HTTPS、全部媒体容器和音频编码。

综合判断：

| 维度 | 当前判断 |
| --- | --- |
| 标准 Xtream API 主路径 | 高兼容，已有自动化和本机 Release 黑盒证据 |
| 常见弱类型/缺字段变体 | 中高兼容，DTO 有针对性容错 |
| Movie/Series 实际播放 | 高兼容于已测 MP4/TS + H.264/HEVC + AAC 矩阵 |
| Basic Live | 已达到既定基础能力边界，不是当前 RC blocker |
| 非标准面板扩展 | 有限兼容，`direct_source`、EPG、catch-up 等未支持 |
| 极端/错误响应 | 部分兼容；`info: []` 是已确认缺口 |
| 正式 RC 状态 | **尚不可进入正式 RC，仅被 `emptyvod` 核心缺陷阻塞** |

## 2. 审计方法与证据等级

本报告把证据分成四级，避免把“代码存在”误写成“真实兼容”：

| 等级 | 含义 |
| --- | --- |
| E1 | 静态代码审计：确认实现路径、边界和失败策略 |
| E2 | 自动测试：使用确定性 fixture 验证协议、DTO、状态和持久化 |
| E3 | 本机黑盒：从 OKVideoMac 正常 UI 进入本机 Xtream Mock，并实际请求/播放 |
| E4 | 多供应商线上验证：不同真实面板、CDN、TLS、负载和媒体库 |

当前证据达到 E3；尚未达到 E4。核心自动回归为 OKVideoKit 254 项、0 失败，以及 macOS 常规测试 700 项、5 跳过、0 失败。最终 Release 已完成账号切换、冷启动、Live 实播与回退复测。

黑盒环境包括：

- IPTVnator Xtream Mock 的正常、过期、禁用、小数据和空 VOD metadata 场景；
- 本机临时目录 中的临时 Mock 扩展，不修改 IPTVnator 原仓库；
- 本地生成的 30 秒 H.264 MP4、H.264 MPEG-TS、HEVC MP4，音频均为 AAC；
- Movie 3 项和 Series Episode 3 项均从 OKVideoMac UI 进入播放器，而不是直接打开 URL；
- Basic Live 的正常 TS、HLS manifest/segment 失败、403、延迟失败和双格式失败场景。

## 3. 原生协议入口与服务器地址兼容性

Native Provider 使用标准 `player_api.php`，支持以下服务器形式：

- `http://host` 和 `https://host`；
- 自定义端口；
- 服务器基础子路径，例如 `https://host:port/iptv/player_api.php`；
- 末尾 `/` 规范化；
- IPv4/域名形式由 Foundation URL 处理，IPv6 未做独立黑盒验收。

明确拒绝：

- 非 HTTP/HTTPS scheme；
- 缺少 host；
- 在 Server URL 中内嵌 `user:password@host`；
- Server URL 自带 query 或 fragment；
- 空白或不安全资源 ID。

这意味着用户应分别填写 Server、Username 和 Password，不能直接粘贴带 `username=`、`password=` 的完整 `player_api.php` URL。

API 请求支持：

| 能力 | action/入口 | 状态 |
| --- | --- | --- |
| 认证 | `player_api.php`，无 action | 支持 |
| Live 分类 | `get_live_categories` | 支持 |
| Live 频道 | `get_live_streams` | 支持 |
| Movie 分类 | `get_vod_categories` | 支持 |
| Movie 列表 | `get_vod_streams` | 支持 |
| Movie 详情 | `get_vod_info&vod_id=...` | 支持，但有 `info: []` 缺陷 |
| Series 分类 | `get_series_categories` | 支持 |
| Series 列表 | `get_series` | 支持 |
| Series 详情/季集 | `get_series_info&series_id=...` | 支持 |
| Short EPG | `get_short_epg` | 当前不调用 |
| Simple data table | `get_simple_data_table` | 当前不调用 |
| XMLTV | credential-bearing XMLTV URL | 当前不支持 |
| M3U `get.php` | Native Provider 路径 | 不使用；仍可作为传统 M3U 导入源处理 |

## 4. 账号认证兼容性

### 4.1 接受规则

账号只有在 `status` 去空白并忽略大小写后为 `Active` 才能使用。以下常见变体已覆盖：

- `auth` 为布尔值、数字 `0/1` 或相应字符串；
- `auth` 缺失但 `status=Active` 的兼容面板；
- `exp_date`、连接数等字段以字符串或数字返回；
- `exp_date` 缺失或不大于 0 时，不主动判过期；
- `allowed_output_formats` 缺失时按空数组处理。

### 4.2 拒绝规则

- `auth=0`：无论 status 是否写成 Active，都拒绝；
- `Expired`、`Disabled`、`Inactive`、`Banned` 及包含这些独立状态词的组合：拒绝；
- `status=Active` 但正数 `exp_date` 已早于当前时间：按 `Expired` 拒绝；
- status 缺失：无效认证响应；
- 未知 status，例如 `Paused`：fail closed，不当成 Active；
- auth 字段为非预期值：解码失败，不把异常值当作“字段缺失”。

过期判定已覆盖测试连接、保存/激活、启动恢复、Home 加载和 Live 播放前认证。最终 Release 实测确认：过期配置不能替换当前有效配置，也不能通过缓存继续表现为正常账号。

### 4.3 账号场景黑盒结果

| 场景 | 实际结果 | 判定 |
| --- | --- | --- |
| 正常完整目录 | 登录、Movie、Series、详情、季集和搜索正常 | Pass |
| `expired`：Active + 过去的 `exp_date` | 启动和激活均明确拒绝为 Expired | Pass（修复后） |
| `inactive`：Disabled | 测试连接和保存均拒绝，没有错误启用 | Pass |
| `minimal`：小数据/边缘字段 | 分类和列表有限结束、搜索完成、无 crash/无限 loading | Pass |
| `emptyvod`：`info: []` | Movie 列表可见，详情立即报 malformed，播放入口不可达 | **Fail / RC blocker** |

## 5. DTO 与响应形态兼容性

当前 DTO 采用“关键 ID 严格、展示字段宽容”的策略：

- 字符串、整数、浮点数和常见布尔表示可在许多非关键字段间转换；
- 缺失或类型异常的可选展示字段通常降级为 `nil`，不会拖垮整个列表；
- Live 的 `stream_id` 和 `category_id` 接受字符串或整数，但拒绝 Bool/Object 被强制当成 ID；
- 不认识的额外 JSON 字段由 `Decodable` 忽略；
- 列表顶层为标准数组时正常解析；
- 列表顶层为 `null` 或空对象 `{}` 时按空列表结束；
- 非空错误对象、HTML、空响应和 malformed JSON 会被区分为明确错误，并且错误文案不回显原始响应体。

Series 兼容两种主流季集形态：

1. `episodes` 是以 season key 分组的对象；
2. `episodes` 是平铺数组，再按每集的 `season` 字段分组。

已知窄口：Movie detail 的 `info` 当前声明为“对象或 null”。某些 Xtream-compatible 面板用空数组 `[]` 表示“无 metadata”，这会造成对象/数组形状不匹配。相同风险理论上也适用于其他本应为对象、却被面板返回空数组的详情字段，尚未逐一做真实面板矩阵。

## 6. Movies 兼容情况

### 已支持

- Movie 分类和按分类目录；
- 本地分页，默认每页 60，构造参数被限制在 1～500；
- 数字或字符串 `stream_id`；
- 标题、海报、评分、年份、类型、导演、演员、简介等可选 metadata；
- 根据详情 `movie_data` 或先前列表缓存恢复 `container_extension`；
- 稳定的 Provider locator，不把含凭据播放 URL 保存为 episode identity；
- 播放前按当前 Keychain 凭据即时生成 URL；
- 历史恢复时从无凭据 locator 重建新 URL，账号改密后不会长期复用旧密码 URL。

标准播放 URL：

```text
<server-base>/movie/<encoded-user>/<encoded-password>/<stream-id>.<extension>
```

`container_extension` 会去除点、转小写并限制为最多 16 个字母数字字符；缺失或不安全值回退为 `mp4`。该安全规则兼容常见 `mp4`、`mkv`、`avi`、`ts` 等扩展，但包含非字母数字符号的私有扩展会被回退。

### 已验证的真实播放

| 媒体 | URL 扩展 | 视频/音频 | Range | 首帧 | seek/EOF |
| --- | --- | --- | --- | --- | --- |
| H.264 MP4 | `.mp4` | H.264 + AAC | 206 | 约 519 ms | 前后 seek 与自然 EOF 通过 |
| H.264 MPEG-TS | `.ts` | H.264 + AAC | 206 | 约 563 ms | 前后 seek 与自然 EOF 通过 |
| HEVC MP4 | `.mp4` | HEVC + AAC | 206 | 约 507 ms | 前后 seek 与自然 EOF 通过 |

三项均由 VideoToolbox 硬解，干净运行 decoder/renderer dropped frame 为 0/0。

### 当前限制

- `info: []` 不能降级为空 metadata；
- `direct_source` 虽可从部分 VOD DTO 读出，但当前 Provider 有意忽略，始终使用标准 Xtream 路径；
- 需要特殊 Referer、Cookie、自定义 Header 或仅能通过 `direct_source` 播放的面板可能失败；
- 尚未真实播放验证 MKV、AVI、FLV、WebM、MPEG-PS 等其他容器；
- 尚未覆盖 AC-3、E-AC-3、DTS、MP3、多音轨、内封/外挂字幕、4K/HDR/Dolby Vision。

## 7. Series 兼容情况

### 已支持

- Series 分类、列表和详情；
- classic season dictionary 与 flat episode array；
- season metadata 缺失时从 episode 的 season 字段派生；
- season `0` 作为未分类 Episodes 处理；
- season number 只接受 0～10,000，异常值被跳过；
- 集数按 `episode_num` 排序，再以 ID 稳定排序；
- 缺少 episode title 时依次回退为本地化集数名或 episode ID；
- 每集独立保留 `container_extension`；
- stable series/season/episode identity；
- 自动从 E01 顺序进入 E02、E03，最终集自然 EOF 后不错误跳转。

标准播放 URL：

```text
<server-base>/series/<encoded-user>/<encoded-password>/<episode-id>.<extension>
```

### 已验证的真实播放

| Episode | URL 扩展 | 视频/音频 | 首帧 | seek/EOF/连播 |
| --- | --- | --- | --- | --- |
| E01 H.264 MP4 | `.mp4` | H.264 + AAC | 约 469 ms | 通过，EOF 后进入 E02 |
| E02 H.264 MPEG-TS | `.ts` | H.264 + AAC | 约 309 ms | 通过，EOF 后进入 E03 |
| E03 HEVC MP4 | `.mp4` | HEVC + AAC | 约 270 ms | 通过，最终集保持结束 |

全部使用 VideoToolbox；干净顺序播放为 0/0 dropped frame。激进快速切集/窗口操作时曾观察到 1～3 个 renderer drop，但 decoder drop 仍为 0，属于压力观察项，不是已确认播放失败。

### 当前限制

- 没有覆盖所有面板对 season/episode 的非标准嵌套方式；
- episode 没有有效 ID 时会安全跳过；所有集均不可用时详情明确失败；
- `direct_source` 当前不使用；
- 未验证超大单剧集列表、极端 season 数量以及真实线上连续长播。

## 8. Search 兼容情况

当前 Search 不是调用面板的搜索 API，而是并行获取完整 VOD 和 Series catalog，在客户端建立统一索引：

- Movie 和 Series 合并搜索；
- 大小写、变音符号和全角/半角不敏感；
- 排序优先级为完全匹配、前缀匹配、包含匹配，再按本地化标题和稳定 ID；
- 使用稳定 summary ID 去重；
- 本地分页；
- catalog/search index 在 Provider 内缓存，默认 TTL 15 分钟；
- catalog 刷新后重建索引；
- 空关键词立即返回空结果。

已验证：

- `minimal` 小数据搜索正常结束；
- 正常 Mock 的 Movie + Series 搜索、详情进入和返回导航通过；
- 10k 与 100k 合成目录能够找到末尾目标，payload 均低于初始 64 MiB safety default；
- 100k 测试是确定性单元/组件压力测试，不是 100k 条真实 UI 滚动、内存峰值或弱网测试。

兼容性代价：不依赖面板是否实现搜索 action，但首次搜索需要下载完整 Movie + Series 列表。超大账号、低带宽或服务器对全量 `get_vod_streams/get_series` 限制严格时，首次搜索成本较高。

## 9. Basic Live 兼容情况

### 已支持

- 仅当前激活 Xtream Provider 暴露一个动态 Live 来源；
- `get_live_categories` 与 `get_live_streams` 并行加载；
- 同名分类用远端 category ID 分离，不会因名字相同合并；
- 缺失或未知 category 进入稳定的 Uncategorized 分组；
- channel identity 由 Provider ID + stream ID 组成，改频道名、换分类或改变格式顺序不会丢身份；
- 同一 Provider 内重复 stream ID 确定性去重；
- 来源、分组、频道、线路搜索和筛选；
- Xtream 收藏/隐藏使用版本化引用，与传统 M3U/TXT/JSON 的旧字符串身份隔离；
- 刷新失败不会删除收藏；隐藏不会自动删除收藏；
- 凭据只在点播放时从 Keychain 读取，并在生成媒体 URL 前重新认证；
- TS/HLS 两个标准候选，按 `container_extension=m3u8` 决定优先顺序；
- 恢复只限当前频道的另一种格式，不会跳到相邻频道；
- 双格式都失败时停留在当前频道并显示失败。

标准 URL：

```text
<server-base>/live/<encoded-user>/<encoded-password>/<stream-id>.ts
<server-base>/live/<encoded-user>/<encoded-password>/<stream-id>.m3u8
```

### 黑盒结果

| Live 场景 | 实际结果 | 判定 |
| --- | --- | --- |
| TS 正常播放 | 从 Release UI 播放到首帧 | Pass |
| HLS manifest 成功但 segment 被拒绝 | 同 stream ID 回退 TS | Pass |
| HLS manifest 403 | 同频道回退 TS，显示恢复提示 | Pass |
| 延迟 HLS segment 拒绝 | 同频道回退 TS | Pass |
| HLS 与 TS 均失败 | 显示失败，不跳邻台 | Pass |
| 10k 频道映射 | 2 个 metadata 请求，约 1.137 秒完成本机组件测试 | Pass（非 UI/非 100k Live） |

HLS 的失败识别与 TS 回退已经实测，但尚缺一条稳定、完全本地的“成功 HLS 长播 + seek/重连”黑盒。因此对 HLS 的结论应是“URL 构造和失败恢复已验证”，不能扩大为“所有 HLS 变体均已验证”。

### 有意不支持

- `direct_source`：Live DTO 明确不保存也不使用；
- Xtream EPG/XMLTV/short EPG；
- catch-up/timeshift/archive；
- Xtream Live 导出成 M3U；
- 多个已保存 Xtream 账号同时聚合为多个动态 Live 来源；
- 跨频道自动恢复；
- 将 Native Xtream 频道持久化为伪 `StoredLiveSource`。

## 10. 网络行为与容量边界

Xtream API 使用独立的 ephemeral URLSession：

- 不接受或持久化 Cookie；
- Cookie storage、URL cache 和 URL credential storage 均为 nil；
- 不写磁盘缓存；
- 不改变其他 Provider 的默认 HTTP 行为；
- API redirect 最多 3 次，只允许 same-origin 且禁止 HTTPS 降级；
- GET 失败最多重试 1 次，覆盖 timeout/transport、408、429 和 5xx；
- 每个 Xtream client 默认最多 2 个并发请求；
- 单请求 timeout 为 30 秒。

响应限制：

- catalog 默认 64 MiB，并使用 opt-in early response limit，在下载过程中即可中止超限响应；
- 64 MiB 是集中、可调的初始安全值，不是 Xtream 协议上限；
- account/detail metadata 为 8 MiB 上限，但当前不是 early limit：URLSession 先完成 body，再做大小检查；
- 10k/100k 搜索 fixture 和 10k Live mapping 均在当前边界内；尚无 100k Live UI、长期内存和弱网验收。

兼容性影响：

- 将 API 从一个 host 跨域 redirect 到另一个 host 的面板会被拒绝；
- HTTPS 降级到 HTTP 会被拒绝；
- 自签名或系统不信任的 HTTPS 证书不会被绕过；
- 极大 catalog 超过当前安全值会明确失败，而不是继续占用无限内存；
- media 由 libmpv 请求，不应把 API URLSession 的 redirect/cookie 结论直接套用到媒体层。

## 11. 播放器与格式兼容性

当前端到端已证明：

```text
container_extension
→ Movie/Series/Live 标准 Xtream URL
→ HTTP Range/206
→ libmpv demux/decode
→ VideoToolbox
→ UI seek/回退
→ natural EOF/Series sequencing
```

本地 Mock 对所有 Movie/Series 媒体正确支持：

- `Accept-Ranges: bytes`；
- `Range: bytes=0-1023` 返回 206；
- 正确 `Content-Length`、`Content-Range` 和 Content-Type；
- libmpv 对 MP4 从 byte 0 请求，对 TS 可先探尾部再回到 byte 0；
- 30 秒文件因缓存较小，后续 UI seek 不一定再次触发网络 Range，但时间码和继续前进已验证 seek 生效。

已验证格式只包括：

- MP4 / H.264 / AAC；
- MPEG-TS / H.264 / AAC；
- MP4 / HEVC(H.265, `hvc1`) / AAC。

因此对 AVI/MKV 等只能说“URL extension 构造可支持且 libmpv 理论具备相应 demux 能力”，不能算本轮真实播放已通过。

## 12. 身份、状态与并发兼容性

实现没有沿用“显示名称或完整 URL 就是身份”的旧模式：

- Provider 配置有稳定 UUID；
- Movie/Series 使用无凭据、版本化 stable locator；
- Live source 使用 `.imported(UUID)` / `.xtream(UUID)` 命名空间；
- Live group/channel identity 不依赖显示名称；
- Xtream favorite/hidden reference 绑定 Provider + stream ID；
- Movie/Series 与 Live reference 使用不同 kind/schema，互相不能误解析；
- 外部 Provider、错误版本、被篡改或非 canonical locator 均 fail closed。

AppState 使用 request ID、当前 Provider 和配置 generation 隔离异步结果。账号切换、改密、删除或退出会使旧任务失效；旧请求不能在稍后覆盖新 catalog 或销毁新播放器。播放器 prepare/stop/close/destroy/load 被统一串行化，已修复旧关闭任务与新播放争用的问题。

对实际兼容性的意义是：频道改名、分组移动和账号改密不会因为旧 URL 或显示名身份造成错误收藏、历史或播放恢复；代价是非 canonical 的外部伪造引用会被拒绝。

## 13. 凭据与隐私安全

### 存储

- Provider descriptor 只保存 version、Provider UUID、显示名和 Server URL；
- `XtreamCredentials` 没有 Codable conformance，不能意外进入配置备份；
- username/password 按 Provider UUID 存入 macOS Keychain generic password；
- Keychain 项设为 `AfterFirstUnlockThisDeviceOnly` 且不参与同步；
- Movie/Series history 只保存无凭据 opaque locator；
- Live catalog、收藏、隐藏、EPG、导出均不保存媒体 URL 或凭据。

### 运行时

- API 凭据按 Xtream 协议进入 `player_api.php` query；播放凭据进入标准 path；
- 日志 redactor 覆盖 Xtream query credentials 和 `/live|movie|series/...` credential path；
- artwork 会拒绝 userinfo、fragment、敏感 query、疑似 credential-bearing Xtream path，以及直接/多次 percent-decoding 后包含当前用户名或密码的值；
- Live 浏览不请求 media、EPG 或 `direct_source`；
- mpv 禁用配置文件、终端、watch-later/history、脚本和路径型日志持久化能力；HTTPS Live load 明确要求 TLS 验证。

最终 Release 的统一日志只读扫描结果：

- username query：0；
- password query：0；
- Mock password：0；
- credential-bearing Live path：0；
- 同一次运行可见 6 个 first-render 和 3 个 VideoToolbox 事件，说明扫描覆盖了真实播放窗口而非空日志。

安全策略会带来两个有意的兼容性取舍：带签名/token 的海报可能不显示；依赖 Cookie、系统 URLCredential 或跨域 API redirect 的面板可能无法连接。

## 14. 传统 Live 回归情况

Native Xtream Basic Live 没有替换原 M3U/TXT/JSON 链路。实测结果：

| 来源 | 首帧 | 解码 | dropped frame |
| --- | ---:| --- | --- |
| M3U | 约 174 ms | H.264 / VideoToolbox | 0/0 |
| TXT | 约 192 ms | H.264 / VideoToolbox | 0/0 |
| JSON | 约 237 ms | H.264 / VideoToolbox | 0/0 |

旧来源的原始字节、ID、解析、分组、筛选、收藏/隐藏、刷新、导出和 direct URL 播放语义均保留。Xtream 的同频道有限恢复不会改变导入源原有的恢复路径。

## 15. 已确认问题与兼容风险分级

### P0 / RC blocker

#### VOD detail 的空数组 metadata

可重复响应：

```json
{"info":[]}
```

实际影响：Movie 列表正常，但详情解码在 Provider fallback 之前失败；用户无法进入播放，即使列表已经提供有效 `stream_id` 和 `container_extension`。

最小修复方向：只把 VOD detail 中已知“空数组代表无对象”的字段规范化为 `nil`，保留非空数组、其他字段和其他 API 的严格形状检查，然后让现有 cached list fallback 工作。必须补充 `info: []`、`movie_data: []`、空对象、null、非空错误数组和正常对象的回归测试。当前报告仅提出方案，没有修改代码。

### P1 / RC 前建议补强

1. 用至少 3～5 个不同 Xtream/XUI 实现做脱敏线上黑盒，覆盖 HTTP、受信任 HTTPS、端口和 base path。
2. 增加稳定成功 HLS 的 30～60 分钟播放、seek、重连和 App sleep/wake 测试。
3. 扩展媒体矩阵：MKV、AVI、HEVC TS、AC-3/E-AC-3、MP3、双音轨、字幕、4K/HDR。
4. 对 100k catalog 做 Release UI 内存峰值、首次搜索时间、取消和弱网测试，而不仅是 fixture 查找正确性。
5. 将 Disabled/Expired 等错误完整本地化；当前行为正确但部分文案仍是英文。
6. 增加专用、脱敏的 authentication verdict 日志，便于现场判断是 auth、status、expiry 还是 transport 失败。

### P2 / 后续独立能力

- 在保持 JIT、安全校验和不落盘前提下评估 `direct_source`；
- Xtream EPG/XMLTV；
- catch-up/timeshift/archive；
- 多 Xtream Live 来源聚合；
- 需要特殊 headers/cookies 的明确配置模型；
- media redirect/CDN/WAF 的跨供应商兼容矩阵。

## 16. 未验证项目清单

以下项目不能根据现有证据宣称支持或不支持：

- 真实商业 Xtream 服务的跨地域网络、限流和连接数策略；
- Cloudflare/WAF、人机验证、IP 白名单、设备绑定、MAC address 绑定；
- API gzip/brotli 极端响应及代理改写；
- 自签名 TLS、企业私有 CA、mTLS；
- IPv6-only 服务；
- API 或媒体跨 host redirect；
- 非 UTF-8 JSON、破损 Unicode、大量重复/冲突 ID；
- 100k Live UI；
- 长时间 HLS、动态 manifest、discontinuity、多码率切换、音频-only Live；
- 多字幕、多音轨、HDR、Dolby Vision、直播时移；
- 供应商私有 action、bouquet、MAG/Stalker/Enigma2 等非 Xtream API。

## 17. Release 与审计完整性

- 已验证 Release：`$HOME/Desktop/OKVideoMac.app`；
- 架构：arm64；版本：0.5.0；Build：99；
- App 和全部内嵌框架通过 `codesign --verify --deep --strict`；
- Release package、ZIP、DMG、源码归档、SBOM、源码—二进制绑定和敏感信息扫描均通过；
- ZIP SHA-256：`83309120d32a427b2065c512034cad826b4da475db5052a008e12ba67f2a71f5`；
- DMG SHA-256：`4025b2ff5d85dfcab8cf35421b5e3006466dab4b30050905d72b6397dde2e172`；
- 当前工作区存在已知未提交实现改动；暂存区为空，分支和 HEAD 未改变；
- 没有修改 Version/Build，没有 tag、push、merge、notarize、GitHub Release 或正式发布。

一次最终复验发现 Finder 给桌面 App 包根附加了 `com.apple.FinderInfo`，严格验签将这种元数据视为 detritus。只移除该可重建 Finder metadata 后，App 与所有内嵌框架再次通过严格验签；二进制和签名内容未被重写。

Android 两个显式真实退出 E2E 因 `/Volumes/XcodeDev/AndroidSDK/platform-tools/adb` 外部卷读取阻塞未完成。这是独立环境问题，不是 Xtream 功能失败；常规 700 项 App 回归已通过。

## 18. 最终结论

当前 OKVideoMac 对 Xtream 的定位应准确表述为：

> 原生支持标准 Xtream Movies、Series、客户端聚合 Search 和 Basic Live；兼容常见弱类型与 Series 结构变体；使用 Keychain、独立网络会话、无凭据稳定引用和播放前即时 URL 解析；已通过本地真实媒体与 Release UI 黑盒，但尚未覆盖所有 Xtream-compatible 私有变体。

Basic Live 已满足当前目标能力，并且没有破坏传统 M3U/TXT/JSON Live。Movies、Series、Search 的正常主路径和六项真实播放矩阵均通过。当前进入正式 RC 的唯一已确认产品阻塞项是 `get_vod_info` 空 metadata 数组兼容缺陷；在该问题被最小修复并复测，或由产品负责人明确书面豁免之前，不建议宣称 0.6.0 Xtream Core 已达到正式 RC。

本报告对应的更细黑盒原始记录位于：

- 本地历史审计记录（不随源码分发）
- `Docs/NATIVE_XTREAM_BASIC_LIVE_STATUS.md`
- `Docs/NATIVE_XTREAM_BASIC_LIVE_CONTRACT.md`
