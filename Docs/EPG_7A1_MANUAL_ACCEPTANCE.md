# EPG 7A.1 人工验收

当前停止点：经授权的本地快照打包已完整通过，等待人工验收。不要替换 Desktop 正式 App，也不要使用旧 7A App 验收新设置。

先退出当前旧版 OKVideoMac，再打开已验证的独立候选：

`/private/tmp/OKVideoMac-Acceptance.Fzrn0M/Artifacts/OKVideoMac.app`

需保存或重新解包时使用仓库中的 `build/EPG71Acceptance-20260910/SourceRelease/OKVideoMac-0.6.1-macOS-arm64.zip`。这是 0.6.1 / Build 101 的本地 ad-hoc Release 候选，未公证、未发布。临时 App 目录可能被系统清理；不要把版本号相同的 Desktop 正式 App 误认为此候选。

## 主流程

1. 使用新的独立 Release 候选，打开“联通”，先确认 CCTV-1 等原频道照常播放；不要编辑直播线路。
2. 设置 → 直播源 → EPG / 节目单：打开总开关，输入你自己的合法 XMLTV/XMLTV.gz 地址。输入尚未保存时不应请求或改变节目单；点击保存后返回 Live，确认 CCTV 的当前/下一节目、时间和进度。不要截图或分享带 token 的地址。
3. 连续快速切换 CCTV-1/2/3/5/5+/13，观察播放不等待 EPG，5 与 5+ 不串台；保持播放跨过一个 programme boundary，再检查当前、下一节目和进度。
4. 删除默认 URL 并保存：“联通”失去节目单。自带 EPG 的 Pluto 源应仍显示节目；先前设置自定义 EPG 的其他源也不受影响。
5. 在“联通”行点击“节目单…”：测试 custom、automatic、disabled。无效 custom 地址应显示错误、保留原有效设置、不关闭 sheet、不 fallback。重新输入有效地址才生效。
6. 总开关关闭：所有源（包括 Pluto 和 Native Xtream）节目单清空，但目录和播放仍正常。重新开启，并快速做 URL A→B→A、模式 automatic→custom→automatic；不能闪回已失效请求的节目。
7. 在联通/Pluto/其他 Source 之间切换，再测试 Mac 睡眠恢复和 App 重回前台：节目按当前设备时间重算，必要刷新异步发生，不串源、不阻塞播放。断网时只应显示仍覆盖当前时间的有效旧节目，不能把过期节目当成当前节目。
8. 重启候选，确认总开关、默认 URL、每源模式和 cuåstom URL 持久化；确认原频道数量及播放线路未改变。

## 判断边界

- 名称不唯一：应显示暂无节目，而不是猜一个。
- 非空但错误的 tvg-id：应暂无节目，不按名称“纠错”。
- 没有 tvg-id 的 CCTV-5+：只能匹配唯一 CCTV5+，不能使用 CCTV5。
- 供应方节目范围不覆盖现在、没有该频道或 HTTP/XML 错误，并不自动等于 UI bug；记录频道名、设备时区、表现即可，不提供完整敏感 URL。
- 滚动流畅度、首帧、快速切台和真实睡眠恢复属于人工体验门，不以单元测试通过代替。

体验通过后再单独决定后续动作；本轮不授权 commit、安装替换、发布或进入 7B。
