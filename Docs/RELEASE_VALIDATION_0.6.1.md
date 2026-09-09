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

## 正式 Release 与分发验证

正式构建从干净提交 `25155f52fb8c416f3245c9a829a93175dec9857b` 执行
`package-app.sh --mode distribution --notarize`，全部门禁通过。
Tag `v0.6.1` 固定该提交；后续文档收尾不重签二进制、不移动 tag、不修改源码归档。

| 检查 | 结果 |
| --- | --- |
| Release / Bundle metadata | 0.6.1（Build 101），macOS 12.0+ |
| 架构 / 依赖闭包 | 29 个 Mach-O 均为 arm64，验证通过 |
| Developer ID | `Developer ID Application: Yao Lin (KGG363ABK9)` |
| Hardened Runtime / 嵌套签名 | `codesign --verify --deep --strict` 通过 |
| Apple notarization | `Accepted`，`Ready for distribution`，无 issues |
| Submission ID | `6da1497c-d7c2-4e0f-b19c-3498e244ffa2` |
| DMG Staple | staple 与 `stapler validate` 通过 |
| Gatekeeper | DMG、盘内及安装 App 均为 `Notarized Developer ID` |
| 安装 smoke | QuickJS、MPV/FFmpeg 初始化、Node/V8 JIT、App 存活检查通过 |
| SBOM | 29 个 Mach-O / 170 个 Maven 模块，验证通过 |
| 制品敏感信息扫描 | `CLEAN` |

最终已 staple DMG SHA-256：

```text
3fcaa402e434298a9fa224c9c4d8f3530be71278c4f0d99629dad40cc6a619f5
```

Apple 日志记录的是提交时、尚未 staple 的 DMG 哈希；下载校验和在 staple 后计算。
安装 smoke 使用隔离用户目录，未卸载用户的真实 Runtime；测试后主动退出 App。
本机 Desktop 应用已替换为从此 DMG 安装、重新通过签名与 Gatekeeper 验证的 Release。
About 从 Bundle 动态读取版本；metadata 已验证，GUI About 尚未可视验证。

签名证书通过本机安全交互导入临时专用 keychain，配置 codesign partition access；
未导入 login/default/system，也未新建证书或重建 `OKVideoMac-Notary` profile。
签名结束后删除临时 keychain，并核实原 search list 和 default keychain 已恢复。
此前 Apple 时间戳服务有间歇性失败；最终仅对该明确错误做有上限的重试，
未关闭时间戳或降低验证门禁。既有 Swift 并发/OpenGL 与 Android lint 诊断保留。

GitHub Release 提供 15 个公开资产，内部 ZIP 不上传。发布正文和当前文档记录最终状态；
随包发布说明和源码归档保留构建提交时的快照，以保证 manifest/SHA256SUMS 可追溯。
既有 `v0.6.0` tag、资产和历史验证记录保持不变。

## English release verification summary

Release `0.6.1 (101)` was packaged from clean commit
`25155f52fb8c416f3245c9a829a93175dec9857b`, pinned by `v0.6.1`. All 29 Mach-O
binaries are arm64 with macOS 12.0 as the deployment target. Developer ID signing,
hardened runtime, nested signatures, Apple notarization (`Accepted`, submission
`6da1497c-d7c2-4e0f-b19c-3498e244ffa2`), DMG stapling, Gatekeeper and installation
smoke tests passed. The SHA-256 above identifies the final stapled DMG.

The full automated suites passed 1060 tests with zero failures and 9 conditional
skips. Android lint succeeded; the JVM test task was `NO-SOURCE`. Initial test-host
configuration failures and conditional skips are recorded above, not counted as
passes. Real user Runtime uninstall and visual About-panel verification were not
performed in this finalization. Existing compiler/lint warnings remain documented.

The certificate was imported only into a temporary dedicated keychain through
local secure interaction. No new certificate or notary profile was created.
The temporary keychain was deleted and the original search list/default verified
restored. Transient timestamp failures received bounded retries without weakening
signature requirements. The Desktop app now points to the verified Release installed
from the notarized DMG. Documentation follow-ups preserve the tag, binary hashes,
and build-time source/notes snapshots. The public release contains 15 assets;
the internal ZIP is not uploaded. Historical v0.6.0 records remain unchanged.
