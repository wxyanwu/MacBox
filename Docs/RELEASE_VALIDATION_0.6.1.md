# OKVideoMac 0.6.1（Build 101）验证记录

日期：2026-09-09。范围：补丁版本、文档及默认分支收口。上一轮已完成的 Managed
卸载代码作为输入，本轮不新增播放器、Provider、Xtream 或卸载功能逻辑。

## 自动测试

| 套件 | 总数 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: | ---: |
| App XCTest | 721 | 713 | 0 | 8 |
| OKVideoKit | 261 | 261 | 0 | 0 |
| AndroidRuntimeKit | 57 | 56 | 0 | 1 |
| Node / CatPaw / Quark | 30 | 30 | 0 | 0 |
| 合计 | 1069 | 1060 | 0 | 9 |

此前的 98 通过 / 1 跳过是卸载功能的定向回归，不是全仓测试总量。本轮执行完整套件。
App 比 0.6.0 的 719 项多了维护请求门禁和运行模式维护冻结两项；RuntimeKit 比 0.6.0
的 36 项多了 20 项维护测试及安装→卸载→重装保留数据测试。

App 默认跳过以下 8 项，未通过排除测试或修改断言制造通过：

- `testRealContractBCompanionConfigurationFromEnvironment`：未提供真实外部配置。
- `testRealContractBSamplesFromEnvironment`：未提供真实外部样本。
- `testAndroidRealApplicationTerminationIsBoundedAndClean`：未启用真实 Android 退出门禁。
- `testAndroidRealExternalModeCoordinatorBridgeDexAndSecondStart`：未启用真实 External E2E。
- `testAndroidRealLifecycleQuitDuringStartupDoesNotOrphan`：未启用真实启动取消门禁。
- `testAndroidRealLifecycleStartAdoptAndStop`：未启用真实私有 AVD 集成门禁。
- `testNativeXtreamAppleFallbackWithAppRendererNetworkGate`：未启用公网/渲染器门禁。
- `testNativeXtreamMuxRedirectWithAppRendererNetworkGate`：未启用公网/渲染器门禁。

RuntimeKit 的 `testProductionCatalogInstallsIntoAnEmptyManagedRoot` 未配置隔离的
在线安装目录，按设计跳过。以上人工/外部验证不能从单元测试结果推断。
维护者反馈真实 Emulator 场景已人工验证且未发现明显问题；本轮没有对用户真实 Runtime
执行卸载，也没有将人工反馈计入自动通过数。

## 测试宿主与初始失败

第一次全量尝试报告 45 次断言失败：临时宿主的单实例标志被关闭，且环境默认英文，
与既有中文文案断言不一致。第二次用应用语言命令参数覆盖 UserDefaults，导致
3 项独立语言偏好测试出现 5 次断言失败。这两次都不是合格的最终测试结果。

最终宿主使用独立 Bundle Identifier；恢复 `LSMultipleInstancesProhibited=true`，
通过进程参数 `-AppleLanguages '(zh-Hans)' -AppleLocale zh_CN` 指定系统语言，
不覆盖应用偏好键。全量重跑成功，所有测试源码和断言保持原样。
中英文资源与显式语言选择仍由现有本地化测试覆盖；这不是完整英文环境的全量断言矩阵。
源码及交付 Release 的单实例保护、Bundle Identifier 和语言设计没有改变。

## Android Bridge

Android lint 与 JVM 单元目标成功；`testReleaseUnitTest` 为 `NO-SOURCE`，不计作有测试通过。
首次直接调用缺少 SDK 路径而停止，之后按现有构建脚本的 SDK/JDK 选择规则重跑成功。
lint 打印了依赖的 Kotlin metadata 2.2.0 与分析器预期 2.0.0 不一致诊断，但 Gradle
最终成功；本轮未调整依赖、lint 规则或测试标准。签名 APK assemble 由完整打包门禁验证。

## Release 与发布边界

提交前的隔离快照已通过完整 local Release `package-app.sh` 门禁。App 与 DMG 的
Bundle metadata 均为 0.6.1（Build 101）；29 个 Mach-O 均为 arm64，并通过本地
ad-hoc Hardened Runtime 签名、依赖闭包和 Bundle 验证。SBOM 覆盖 170 个 Maven
模块，最终 15 个发布制品的敏感信息扫描状态为 `CLEAN`。真实提交完成后仍需从
该 clean commit 重跑同一门禁，最终报告以真实提交生成的制品为准。

About 使用 Bundle 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`，
无新增显示版本来源。Bundle metadata 已验证；GUI About 尚未可视验证。

本轮目标是默认分支源码收口和本地 Release 验证。Apple notarization、Staple、
Gatekeeper 公证评估和公开 DMG 发布未执行，不宣称通过。
按照现有 DMG 发布流程，`v0.6.1` 留待正式公证资产及安装 smoke 门禁通过后创建。
已有 `v0.6.0` 和 `RELEASE_NOTES_0.6.0.md` 不变。
