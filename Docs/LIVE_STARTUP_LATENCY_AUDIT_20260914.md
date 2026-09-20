# 直播首帧慢：实测定位与修复建议

诊断日期：2026-09-14，Asia/Shanghai。范围：截图中的 mock Native Xtream 直播来源。此次完成只读诊断、临时实验和本报告；未修改播放器业务代码，未打包或替换 App。现有工作区改动保留。

## 结论

当前已证实的主要瓶颈是 **HLS 主列表展开时，播放器顺序打开多个清晰度和音频组合的子列表及媒体数据**。选择最终音视频轨道之前，网络耗时已被这些请求不断累加。应用现有 HLS 精简逻辑仅在首条线路失败后的备用 HLS 尝试生效，因此“首条线路很慢但最终能播”的情况不会获得优化。

实际 App 三次起播中，媒体打开阶段占总耗时约 95%～97%；播放器创建、窗口准备和加载后的画面呈现都不是主要瓶颈。独立使用当前 Release 内置 libmpv 的 Mux 实验，在保持 1080p 和音频的情况下，原路径启动 20.992 秒，提前选定单一变体后，包含主列表获取、重定向和播放器进程开销的完整诊断流程为 6.343 秒，单次对照约减少 70%。这证明修复方向有效，但不是已安装 App 的优化后首帧成绩，也不是 IPTVX 对比成绩。

## 实际 App 的分段耗时

运行包：`~/Applications/OKVideoMac-Local/25155f52fb8c416f3245c9a829a93175dec9857b/OKVideoMac.app`，CFBundleVersion 为 101，进程 3857。通过 Computer Use 读取当前页面，确认来源为 mock、三个频道与用户截图一致。没有改变来源、线路或播放器设置。

来自已有 MPV-PERF 日志，单位为秒：

| 点击时间 | 点击到 loadfile | loadfile 到 file_loaded | file_loaded 到首次 render swap | 点击到首次 render swap |
| --- | ---: | ---: | ---: | ---: |
| 22:54:16 | 0.482 | 23.385 | 0.235 | 24.103 |
| 22:58:21 | 1.351 | 28.003 | 0.074 | 29.428 |
| 22:59:03 | 0.472 | 20.858 | 0.075 | 21.405 |

单独的 click_to_client_ready 为 123、78、98 ms，已包含在第一列中，不能再次相加，也不等于纯构造函数耗时。三个请求均记录 `nativeXtream` 的 HTTP 代理路径。开始播放后的采样显示 VideoToolbox 解码、0 掉帧。

日志没有记录频道名称，故不把这三次历史请求强行对应到特定频道。`first_render_swap` 是应用当前的首帧代理指标，没有同步高速摄影验证像素真正出现在屏幕上的瞬间。这个局限不影响“二十多秒主要发生在 file_loaded 之前”的判断。

原始阶段日志：[app-startup.log](/private/tmp/okvideo-live-startup-audit.26Dgei/app-startup.log)。

## 为什么这些频道会触发慢路径

公开 mock 服务明确允许任意测试用户名、密码。诊断使用自行构造的 `diagnostic/diagnostic`，没有读取用户 Keychain。

| 页面频道 | `.ts` 入口实际 302 到 | 主列表变体数 | 现有选流限制 |
| --- | --- | ---: | --- |
| Apple Test Channel | Apple bipbop HEVC 示例 master.m3u8 | 54 | 只有进入第二格式回退才会尝试精简 |
| Mux Test Channel | Mux x36xhzz.m3u8 | 5 | 还被“至少 12 个变体”限制排除 |
| Open HLS Channel | Mux test_001/stream.m3u8 | 6 | 变体数不足，而且列表没有 CODECS 属性 |

“TS”是请求线路的声明格式，不能当作响应内容的实测格式。不能为了快而按 `.ts` 后缀强制 MPEG-TS 解复用器。

当前主要入口是 [AppState.swift:13339](../OKVideoMac/macOS/OKVideoMac/App/AppState.swift#L13339)：必须满足 `skippedCount > 0`、Native Xtream、声明 `format == "m3u8"` 才准备 HLS 精简列表。

[HLSStartupSelection.swift:48](../OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Playback/HLSStartupSelection.swift#L48) 又要求至少 12 个变体，并限制 H.264/AAC、最高 1080p/60、有 CODECS 和 RESOLUTION。它是有意保守的失败恢复方案，不是通用首播优化。

本机 mpv 0.41.0 源码中，HLS 的 `no_stream` 路径会交由 FFmpeg 重新打开媒体入口；随后 FFmpeg 的 `hls_read_header` 先遍历各子播放列表，再为各列表打开媒体解复用器。顶层 `avformat_find_stream_info` 和最终轨道选择发生在其后。[mpv 0.41.0 源码](https://github.com/mpv-player/mpv/blob/v0.41.0/demux/demux_lavf.c)，[本机 FFmpeg 源码](/Volumes/XcodeDev/OKVideoMacBuild/Source/MediaDeps/ffmpeg-7.1.4/libavformat/hls.c:1993)。运行期下述请求日志直接证实了遍历行为。

Mux 原路径本次分段：

| 播放器计时范围 | 已观察到的行为 |
| --- | --- |
| 0～2.787 秒 | 请求 mock 入口、重定向、读到主列表并识别 HLS |
| 2.787～5.573 秒 | HLS 重新打开阶段，之后开始读第一个子列表；需要 HTTP 级埋点才能进一步精确拆分重定向、连接和重读成本 |
| 5.573～7.809 秒 | 顺序打开全部 5 个清晰度的子列表 |
| 7.809～20.815 秒 | 每种清晰度均打开媒体分片，共记录 10 次分片打开 |
| 20.815～20.839 秒 | 顶层流信息探测结束 |
| 20.841 秒 | FILE_LOADED，选择 1080p 视频和 AAC 音频 |
| 20.992 秒 | 无界面 PLAYBACK_RESTART |

因此这次二十多秒不能归咎于“顶层 find_stream_info 分析了很久”：仅关闭该调用，仍然绕不过其前面的 HLS 子列表及媒体打开。`hls-bitrate` 是默认轨道选择策略，单独调低它也不能保证避免前面的多变体打开。[mpv 参数说明](https://mpv.io/manual/stable/)。

## 同一 Release 播放器库的对照

临时 C 程序链接当前运行包内的 libmpv，使用同一系统 HTTP 代理，缓存参数与 balanced 配置一致。音视频输出使用 `vo=null`、`ao=null`，因此测量 FILE_LOADED 和 PLAYBACK_RESTART，不冒充可见首帧，也不验证真实音响或显示输出。保留网络 TLS 校验。诊断额外设置 15 秒网络超时、65 秒总停止预算；日志报告某些 timeout AVOption 未应用，故不把它当作有效生产超时策略。

| 对照 | FILE_LOADED | PLAYBACK_RESTART | 说明 |
| --- | ---: | ---: | --- |
| Mux 原 `.ts` 重定向入口 | 20.841 秒 | 20.992 秒 | 10 条音视频轨道，最终 1920×1080 |
| Mux 预备好的单变体主列表 | 3.999 秒 | 4.131 秒 | 2 条音视频轨道，仍为 1920×1080；不含主列表准备 |
| Mux 重新从入口获取、选流后加载 | 3.937 秒 | 4.056 秒 | 准备耗时另计 2.247 秒，含进程开销和退出的全流程为 6.343 秒 |
| Apple 原 `.ts` 重定向入口 | 未到达 | 未到达 | 本次较慢网络下 65.076 秒达到诊断上限；已打开 57 次子列表，仍在逐路打开媒体 |
| Apple 使用项目现有 selector 生成精简主列表 | 13.497 秒 | 13.620 秒 | 保留 v9 的 1080p/60、a1 AAC 音频及关联字幕/CC 声明；不含前置主列表获取 |

Apple 结果说明减少变体仍有很大价值，也说明“只提前选流就能稳定一秒首帧”没有证据：选中媒体自身的 Range 请求和网络往返仍有十余秒成本。Apple 的日志还报告现有 FFmpeg 不支持该外置字幕 URI；本次未改变字幕能力，保留声明并不等于已验证字幕呈现。

实验是按顺序运行的少量诊断样本，没有足够样本计算 p50/p95，也没有固定 CDN、代理缓存和连接冷暖状态。以上约 70% 是本次完整 Mux 对照的结果，不是所有来源的保证。没有对 IPTVX 做同源同画质实测，不能断言其使用了哪种私有优化。当前三个是公开测试样例；不能用它们替代真实滚动直播的直播边缘与延迟验收。

可复核材料都在临时目录（清理临时文件后会失效）：[诊断程序](/private/tmp/okvideo-live-startup-audit.26Dgei/probe.c)、[完整计时脚本](/private/tmp/okvideo-live-startup-audit.26Dgei/benchmark.py)、[Mux 原路径日志](/private/tmp/okvideo-live-startup-audit.26Dgei/mux-baseline.log)、[Mux 完整准备对照日志](/private/tmp/okvideo-live-startup-audit.26Dgei/mux-full-preparation.log)、[Apple 原路径日志](/private/tmp/okvideo-live-startup-audit.26Dgei/apple-baseline.log)、[Apple 精简日志](/private/tmp/okvideo-live-startup-audit.26Dgei/apple-selected-data.log)。

复现识别用库 SHA-256：

```text
libmpv.dylib         6f2f7f53ed3ec1309ae6cef869dd8a83bb4bfff09ad9d61a87f6e2f5778b0cd4
libavformat.61.dylib 75f3aa0d50d57688618849ed2814ff4eaeaab3870f0d232004ff63d5b282bcf0
```

## 建议实施顺序

1. **先把 HLS 内容识别、选流放到第一次播放。** 引入独立的直播起播准备层，由它统一处理实际响应类型、重定向后的基准 URL、主列表和选中的音视频组。已知 HLS 或已有格式观察的线路直接进入该层；`.ts` 返回 HLS 时也应进入。获取一次有大小和总时间上限的主列表，并把结果交给播放器复用；避免 HEAD、GET、播放器再 GET 三轮串行探测。真实连续 TS 应尽快移交播放器，不能为了找 HLS 等完整响应结束，也不能额外开启长时间探测连接。

2. **通用化 selector，保留媒体语义。** 对具有多种清晰度的普通主列表就有收益，不应由 12 这个数量决定。先覆盖普通 H.264/AAC 多变体，保留用户画质和音轨偏好；正确带上所选变体关联的 AUDIO、SUBTITLES、CLOSED-CAPTIONS。Apple 不能只传 v9 子列表，否则可能变成无声视频。Mux Open 的 CODECS 缺失需要单独的有界判断/回退设计，不能仅删除校验后宣称兼容。未知扩展、变量、会话密钥、内容引导、LL-HLS、独立视频组等未支持语义应保留原加载路径。密钥、分片和媒体列表继续由 libmpv 正常处理，不重写分片内容或直播序列。

3. **为直播建立独立起播预算和可取消回退。** 当前 Native 单候选可等 60 秒，并且等待的是 load 完成；应区分准备、连接/打开、已有媒体后等待首帧三个阶段，增加没有进展时的有界回退。3～5 秒可作为快路径无进展预算的实验起点，必须结合网络和服务端并发连接限制验证，不把慢但正在前进的连接无条件杀掉，也不把全部备用线路同时预连。保留取消、请求所有权检查、旧会话释放、账户错误终止和当前频道范围恢复。端到端 deadline 应覆盖准备、加载以及首帧；缩短一个 timeout 数字本身不会让有效线路更快。

4. **再做残余优化。** 将真实 TS 的流分析预算单独实验，例如从 0.5～1 秒和有界 probe 数据量起步；缺失轨道信息时回到兼容配置。HLS 不全局关闭 probe-info，也不把 `cache=no` 当作通用方案。直播起播阈值与播放后的前向缓冲分别调节，保留抗网络抖动能力。账户认证与渲染表面准备可在保持现有认证授权要求的前提下重叠执行；只在证据支持时考虑短期、可失效的格式/变体偏好缓存，不持久化含凭据的播放 URL。Apple 精简后的多次 Range 打开，应进一步量测 TCP/TLS、复用、响应首字节和传输量，再决定是否改网络层。

`cache-secs=60` 表示预读目标，不是首播必须等待 60 秒。此次诊断读取到 `cache-pause-initial=no`，与实测加载完成后很快进入播放相符。不能把预读长度、重新缓冲阈值、首帧时间和直播落后时长混为一谈。[mpv 缓冲参数说明](https://mpv.io/manual/stable/#cache)。

播放器重建目前只贡献不到约 0.13 秒的点击到就绪时间，不应优先通过常驻所有播放器来追求秒开。现有 EPG 工作也不在已定位的二十多秒播放器媒体打开阶段。

## 验收标准

实现第一阶段后，重新用真实 Release App 从用户点击开始测到可见视频帧并确认音频正常。为每次请求记录不含 URL/凭据的阶段耗时、实际协议、主列表/选中变体数量、重定向次数、首字节、媒体打开、首帧与失败/取消原因；请求数量需要独立计数，不能只凭“感觉更快”。

至少覆盖截图三个频道、真实连续 TS、普通滚动 HLS、音视频分离、AES-128、fMP4/BYTERANGE、重定向、响应格式与后缀不符、鉴权失败，以及快速换台/关闭。每种关键路径做冷、暖各至少 10 次，报告中位数和 p95，记录实际画质、音频选择、首帧后重缓冲。与 IPTVX 比较必须同机、同线路/最终来源、同网络代理、同画质，区分冷启动和换台。

第一阶段合理目标是消除未选择清晰度的媒体请求，并在同等测试条件下使 Mux 端到端起播显著下降（本次原型给出约 70% 的方向性证据）。正常低延迟网络下可以再设“中位数 2～3 秒、p95 5 秒”的产品目标；本次网络实测尚未达到，不能将目标写成已经实现的承诺。Apple、慢源和长 GOP 源应单独报告。

只有实现、音视频回归与真实首帧验收完成后，才按项目要求构建并验证 Release 包、再安装桌面 App。此次请求为定位及修复建议，尚未进入实施交付。
