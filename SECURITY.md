# Security Policy

请勿在公开 issue、pull request、日志或附件中提交 token、Cookie、OAuth
credential、账号密码、API key、私人内容源 URL、私人媒体历史或个人数据。

如果发现 secret exposure、credential leak、可疑的包行为或其他安全问题，且
仓库当前没有公布专用安全邮箱或私下披露渠道，请在公开 issue 中只描述不含敏感
细节的概要，并等待 maintainer 指示安全提交方式。不要公开粘贴可复现凭据、
私有链接、完整利用细节或未脱敏日志。

报告时请说明受影响版本、macOS/硬件环境、Native Mode 或 Android
Compatibility Mode、影响范围和已采取的临时缓解措施。若凭据可能已经泄露，
应立即在对应服务撤销或轮换；从仓库删除字符串不能替代凭据轮换。

## Native Xtream 凭据与网络

Native Xtream 的 username/password 按 Provider UUID 保存在设备本地 Keychain，
不写入 UserDefaults、数据库明文、历史或便携备份。配置恢复需重新输入账号。
媒体 URL 只在运行时生成；诊断不得记录完整账号地址、代理密码或授权 token。
Native Live 代理决策按播放器实例隔离，不修改 App 进程的全局代理环境变量。
当前静态 HTTP 代理支持不代表 PAC、SOCKS、认证代理或逐 URL 系统路由完整兼容。
