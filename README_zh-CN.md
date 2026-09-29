# MacBox

**Mac 上的 TVBox 兼容播放器**

**支持 Android TVBox 订阅配置**

简体中文 | [English](README.md)

MacBox 是基于 [OKVideoMac](https://github.com/yaolin-dev/OKVideoMac) 开发、独立维护的项目，
以 Android TVBox 订阅兼容、播放稳定性和原生 Mac 使用体验为重点。
OKVideoMac 是代码来源，Android TVBox 是兼容目标；MacBox 与上游独立维护和发布，不代表上游官方版本。

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple&logoColor=white)
[![GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)

## 当前状态

- 当前应用版本：1.1.0（Build 103）
- 上游代码基线：OKVideoMac 0.6.1，提交 `9970e2c`。
- 产品分支：`main`。应用及安装包名称为 MacBox，使用独立版本号；使用独立的 MacBox 图标。
- 当前开发及实际验收以 Apple Silicon（M 系列）Mac 为主，最低部署目标为 macOS 12.0。
- Intel Mac、iPhone 和 iPad 尚未完成适配验收。

## 主要功能与改进

- 点播与直播，支持 Android TVBox 配置，以及原项目已有的 Xtream、M3U/XMLTV 等来源。
- 原生 Swift/SwiftUI/AppKit 界面，使用 libmpv 播放；部分 JavaScript 站点使用 QuickJS 或 Node。
- Java/DEX 站点按需使用本机 Android Bridge 和兼容运行环境。
- 改进 Gson 风格订阅解析、配置请求、安卓播放格式识别与播放地址刷新重试。
- 片头、片尾时间按剧记忆，单行按钮可取当前播放时间，时间框支持按秒调整，并在连续选集时生效。
- 可选跳过 VOD HLS 播放列表中明确且完整标记的广告区间，默认关闭。
- 搜索前检查 Android Bridge 状态，遇到旧请求卡住时恢复，并准确统计可搜索站点。
- 修复设置页宽度适配、直播源检测引起的全局刷新，以及播放时屏幕空闲休眠问题。
- 加入 CoreAudio 回调生命周期保护，处理音频设备变化时的潜在崩溃。
- 完整 Android 组件采用无损压缩镜像；已验证样本中，组件占用由约 5.35 GiB 降至 1.82 GiB。
  此数字不含 Android 用户数据、备份和安装临时空间，也不代表首次下载量。

订阅是否可用取决于其站点、插件、网络和媒体服务。部分实际样本已完成搜索、详情和播放验收，
不能据此保证所有 Android TVBox 订阅或其中所有站点都可用。

## 安装与使用

本项目当前使用经过本地验证的 Release 构建，采用 ad-hoc 签名。
它不是上游 Developer ID 签名及 Apple 公证的安装包；上游下载页提供的也不是本项目修改版。

[下载 MacBox 1.1.0（Apple Silicon Mac）](https://github.com/wxyanwu/MacBox/releases/download/v1.1.0/MacBox-1.1.0.dmg) · [发布说明、校验文件与对应源码](https://github.com/wxyanwu/MacBox/releases/tag/v1.1.0)

1. 使用本项目构建的 Release 应用。
2. 在“设置 → 点播片源”导入你自己的 TVBox 配置；直播来源在“设置 → 直播源”管理。
3. 遇到 Java/DEX 站点时，按应用提示准备 Android 兼容组件；不要求安装 Android Studio。
4. 选择站点，搜索或浏览内容，再选择线路和集数播放。

Android 兼容组件不是完整内置于 App 的离线资源；首次安装需要联网下载并接受相关组件许可。
当前仍保留上游内部 Bundle ID 和数据目录，以延续已有订阅、偏好与观看记录；原版和修改版不应视为数据互相隔离的两个应用。

## 开发与项目来源

- 本项目仓库：[wxyanwu/MacBox](https://github.com/wxyanwu/MacBox)。
- 上游仓库：[yaolin-dev/OKVideoMac](https://github.com/yaolin-dev/OKVideoMac)。
- `origin` 用于本项目维护，`upstream` 用于跟踪原项目；保留原有 Git 历史和归属信息。
- [构建说明](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [架构说明](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [Android 兼容环境](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP_zh-CN.md)
- [运行环境存储与卸载](Docs/ANDROID_MANAGED_UNINSTALL.md)
- [历史更新记录](CHANGELOG.md)

源码目录、工程名及部分技术文档仍使用 OKVideoMac。历史发布说明、截图和验收数据描述其记录时的版本，
不能自动当作 MacBox 当前版本的发布或验收结论。

## 内容与隐私

MacBox 不内置影视订阅、媒体资源、账号、Cookie、解析服务或 DRM 密钥。
请只导入你有权使用且信任的配置、脚本和媒体；第三方订阅插件能够执行代码并访问网络。

## 许可证与版权

原项目自有代码采用 [GPL-3.0-only](LICENSE)，本项目基于该许可继续维护。
保留原作者 Yao Lin、其他贡献者及第三方组件的版权和许可证；更名不改变原代码的归属。

详见 [来源与修改声明](OKVideoMac/NOTICE.md)、[第三方声明](OKVideoMac/THIRD_PARTY_NOTICES.md)
和 [二进制与源码对应关系](Docs/BINARY_SOURCE_MAPPING.md)。
