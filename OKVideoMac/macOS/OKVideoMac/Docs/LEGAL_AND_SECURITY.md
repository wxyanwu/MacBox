# Legal and Security

- 项目以 FongMi/TV 的 GPL-3.0 协议和业务行为作为兼容参考，保留来源与修改说明。
- 不内置未经授权的影视源、配置、解析服务、账号、Cookie、Token 或 DRM 密钥。
- 测试只使用本地生成、保留域名 `example.invalid` 和明确授权的公开媒体。
- 不实现 DRM 绕过、付费验证绕过、凭据收集或远程 Shell。
- QuickJS Host API 不提供文件和进程访问；网络必须经过应用 HTTP 策略。
- WKWebView 使用非持久化存储，拦截危险 Scheme，消息桥仅接收媒体候选 URL。
- 配置可能包含用户主动提供的敏感 Header。离线副本不可避免地保存原始配置，
  但应用不复制这些字段到历史表，日志和诊断包必须脱敏。
- App Sandbox 在非 App Store MVP 中关闭；这不是安全保证。所有输入验证仍必须
  在应用层执行。


## Native Xtream 凭据与网络

Native Xtream 的 username/password 按 Provider UUID 保存在设备本地 Keychain，
不写入 UserDefaults、数据库明文、历史或便携备份。配置恢复需重新输入账号。
媒体 URL 只在运行时生成；诊断不得记录完整账号地址、代理密码或授权 token。
Native Live 代理决策按播放器实例隔离，不修改 App 进程的全局代理环境变量。
当前静态 HTTP 代理支持不代表 PAC、SOCKS、认证代理或逐 URL 系统路由完整兼容。
