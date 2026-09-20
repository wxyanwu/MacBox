# OKVideoMac 0.7.0（Build 102）Release Notes

日期：2026-09-19

## 弹幕

- TVBox、CatPawOpen 与 Xtream 共用一套原生弹幕核心；源直接提供本集弹幕时可自动加载。
- 支持 Bilibili XML、本地文件导入、手动搜索与候选选择，并按配置、站点、内容、分集和版本保存选择与时间偏移。
- 播放器面板提供开关、来源、字号、透明度、显示区域、密度和 ±0.5 秒校准。
- MPV 是唯一媒体时间权威；暂停、缓冲、seek、倍速、窗口变化和换集都会重新锚定或清理旧轨道。
- CatPaw `danmuPush` 绑定精确播放请求与 generation，旧集迟到结果不会污染新集；用户手动选择不会被自动结果覆盖。
- 弹幕获取、解析或显示失败不会阻塞或终止视频播放。

## 数据与兼容

- 弹幕绑定独立于观看历史，清除历史不会删除绑定；删除配置会删除所属绑定。
- 便携备份 schema 升至 3，继续兼容旧备份，并只保存稳定 locator；签名 URL、Cookie、请求头和本机代理 lease 不进入备份。
- 外部自动匹配保持关闭。Xtream 没有源弹幕协议时，可由用户配置外部弹幕服务或导入 XML。

## 验证

- Danmaku 专项：12 通过，0 失败。
- OKVideoKit：869 通过，10 条显式实验测试跳过，0 失败。
- macOS 应用测试：886 通过，8 条条件测试跳过，0 失败。
- Release 包通过 bundle、签名、SBOM、敏感信息和解包验证后才用于桌面验收。

本次交付是本地 ad-hoc 签名验收包，未进行 Apple 公证，不替代目前公开的 0.6.1 公证版本；本轮不创建 Git tag 或公开 Release。

---

# OKVideoMac 0.7.0 (Build 102)

Date: 2026-09-19

This release adds one native danmaku pipeline shared by TVBox, CatPawOpen and
Xtream playback. It supports source-provided comments, Bilibili XML import,
manual search and selection, persistent per-edition bindings, time calibration,
and an AppKit overlay anchored to MPV media time. Danmaku failures never block
video playback, stale callbacks are scoped to the exact playback generation,
and runtime URLs or credentials are excluded from portable backups.

The delivered build is a locally verified ad-hoc acceptance package. It is not
notarized and does not replace the current public 0.6.1 notarized release.
