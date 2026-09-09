# Managed Android 卸载与存储管理（0.6.1 / Build 101）

本功能只处理 OKVideoMac 可识别的 Managed 安装内容。保留 `avd/`、
`home/`、AVD backing/encryption 文件、登录状态、私有 `adbkey` / `adbkey.pub`、
用户数据备份和 `runtime-selection.json`；External SDK
始终排除。首版没有删除 Android 用户数据的入口。

## 删除计划与边界

`RuntimeMaintenanceService.prepareManagedUninstall()` 是只读 dry-run：
返回计划 ID、相对路径、类别、实际分配空间估算、保留项和文件身份快照，
不会创建锁文件或维护目录。可用 JSONEncoder 打印完整计划；导出诊断也包含
最近计划及磁盘上的事务记录，不记录 External 的绝对路径或密钥内容。

计划默认 120 秒有效，只能使用一次；再次 prepare 会使上次计划失效。
执行 API 只接受 plan ID，从服务内部查找快照。取得排他维护锁、停止会话后，
重新检查有效期、运行模式记录、目录身份和完整文件快照。变化或过期必须重新确认，
不会扩大此前确认的删除范围。

只识别当前 catalog 的 generation、对应下载文件、具有安装事务记录的 staging、
具有匹配 manifest 的纯 generation backup，以及关联安装元数据。
未知或混合备份保留。所有遍历、移动和删除使用目录描述符及 no-follow 操作；
拒绝越界、跨设备、身份变化和硬链接文件。允许安装包内部安全的相对符号链接，
删除链接本身，不跟随目标。

## 会话与事务

1. 阻止模式切换、安装/修复、新 Bridge 请求和新的 Android 启动。
2. 取消并等待已有 Bridge 操作，停止本应用的 Android 会话。
3. 校验 Emulator、私有 ADB 的退出与占用。无法确认则不卸载；External 模式同样要求停止本应用会话。
4. 重验计划，持久化 `Maintenance/<transaction-id>/transaction.json`。
5. 先隔离 active pointer，再隔离计划内内容到事务的 `quarantine/`。
6. 提交前失败恢复原位置，最后恢复 pointer；恢复失败保留事务和剩余内容。
7. 提交后逐项删除隔离内容，记录结果。部分失败保留待清理状态，重启或设置页可继续。

安装和 rollback 使用共享文件锁，卸载使用排他文件锁。未完成或损坏的卸载事务
会阻止重新启动、安装和修复，避免在中间状态继续工作。
`Backups/` 不承担隔离职责。已完成事务保留小型诊断记录。

## 界面与空间口径

设置 → Android Compatibility 提供 Managed 组件卸载按钮、确认、忙碌状态、结果及恢复入口。
空间分开显示组件、缓存、用户数据和备份；使用实际分配块数，作为近似值，
不承诺等于 APFS 最终可回收空间。确认框使用本次计划估算，不用整个 AndroidRuntime 总量。

## 验证与限制

- RuntimeKit：57 项，56 通过、1 项真实网络下载测试按默认配置跳过，零失败。
- App 定向回归：42 项通过，覆盖维护请求门禁、运行模式、生命周期、归属策略和本地化。
- 隔离测试覆盖 dry-run 无写入、过期/复用/文件替换、External 排除、符号链接、安装互斥、
  停止失败、提交前恢复、恢复失败、部分删除后重启恢复、恶意日志、混合备份和安装→卸载→重装保留数据。
- 维护者确认已完成人工真实 Emulator 场景验证，未发现明显问题；这属于人工反馈，
  不计作自动测试通过，也不代表完整 macOS/Emulator/ADB offline 矩阵已覆盖。
- 本轮版本收口不在用户真实 AndroidRuntime 上执行卸载。完整自动测试与构建记录见
  [0.6.1 验证记录](RELEASE_VALIDATION_0.6.1.md)。
- App 测试使用隔离的 Debug 测试宿主；最终交付必须经过完整 Release 打包和 bundle 验证。

## 卸载后的使用

卸载组件不会抹除 Android 用户数据。之后可从设置重新安装 Managed components；
重新启动仍须满足既有 AVD 兼容性检查。保留 External 选择不等于改为 Managed 模式。

组件与数据分开管理：纯 generation backup 可以进入卸载计划，AVD/用户数据备份及
无法确认类别的混合备份继续保留。`Maintenance/` 中的隔离内容是删除事务的一部分，
不作为普通 Backup 展示；诊断保留事务状态，设置页提供待清理操作的继续入口。
