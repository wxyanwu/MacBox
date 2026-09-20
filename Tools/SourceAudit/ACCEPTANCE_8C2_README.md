# OKVideoMac 8C.2 — 本地隔离验收

这是 macOS Apple Silicon 的本地 Release 验收目录，不是正式发布。无需 Python/Xcode；不要单独双击 App，也不要移动目录里的单个文件。

## 第一次启动

1. 自行退出所有 OKVideoMac（正式版及验收版）。启动器只拒绝冲突，不会关闭已有进程。
2. 双击 `Initialize-8C2.command`，显式创建空的 `/private/tmp/OKVideoMac-8B3B-RouteD.*` 数据目录。
3. 双击 `Launch-8C2.command`。首次没有私人源、账号和历史，请自行导入合法测试源。
4. 正常退出 App，第二次直接运行 `Launch-8C2.command`，复用同一个隔离目录。

`acceptance8b3b` bundle ID、`OKVIDEOMAC_8B3B_ROOT` 和目录前缀是冻结的历史安全 identity，不代表当前仍处于 8B.3B。

启动前核对 App 文件清单/摘要、冻结源码摘要、版本、签名、隔离路径与权限；启动后核对 PID 的实际 executable path。任何校验失败都返回非零，不会回退到正式 Library 数据目录。环境变量只传给该 App 及子进程，不使用 launchctl。

## 维护者显式指定已有验收目录

在此交付目录打开 Terminal，执行：

```sh
./AcceptanceLauncher --check --root /private/tmp/OKVideoMac-8B3B-你的验收目录
./AcceptanceLauncher --root /private/tmp/OKVideoMac-8B3B-你的验收目录
```

不存在、符号链接、硬链接、错误权限或不可写路径都会拒绝。不会自动修权限、恢复数据库或迁移真实用户数据。

## 保留和交付

- `/private/tmp` 可能被系统清理。目录丢失时明确拒绝，不会偷偷创建空库；需要重新显式初始化。
- `AcceptanceWorkspace.json` 是初始化后产生的本机路径配置，不随跨机器转交保留。
- 不要转交私人的 Application Support、缓存、Cookie、账号或数据库。交付目录初始仅有 App、launcher、manifest、两份 command 和本说明。
- 移动交付目录后仍按相邻路径解析 App；不要修改已封存的 App 内容。
- manifest 是验收完整性记录，不是第三方防伪签名；需通过可信渠道获取整个目录及其摘要。
- 签名为 local ad-hoc，没有 Developer ID notarization；Gatekeeper/跨机器信任不是本次通过项。本启动器不会移除 quarantine 或绕过系统安全策略。
- 没有安装、Desktop 替换、版本变更、公开发布或 8C.3 频道 merge/split。
