# EPG 9B.3 网络到流式解析实现报告

日期：2026-09-19

## 基线与分支

- 开发分支：`codex/epg-9b3-download`
- 基础 Git HEAD：`14dd3a584f49bdb67a5b7edd25c9980f77f480e2`
- 开工前已验证 0.7.0 Build 102 本地验收源码 SHA-256：`ae88a474b727b1d7f7f7076c172d43a597048c5b4f5034f39bed9eac203c3920`
- 开工前验收源码文件数：554

切分支时完整保留了工作区内既有 EPG、跳过片头片尾、弹幕及发布改动；没有 reset、stash、clean 或覆盖旧改动。

## 本阶段结论

9B.3 的独立链路已经成立：

```text
URLSessionDownloadTask
  -> Foundation 临时文件
  -> 回调内 O_NOFOLLOW 打开并固定文件描述符
  -> 独立 utility 队列、固定 64 KiB 缓冲复制
  -> XMLTVStagingFile 单次所有权转移
  -> 普通 XML / gzip 魔数识别
  -> 同步 XMLTV 批次解析与背压
```

本阶段仍是 `XMLTVStreaming` SPI。正式 `XMLTVService`、`EPGRepository`、缓存 JSON 和 App 调用路径保持冻结；它们仍使用旧的完整 `Data` / `XMLTVGuide` 路径。9B.3 证明低内存链路可行，不代表生产 EPG 已切换完成。

## 固定资源合同

- 下载/压缩输入上限：32 MiB。
- 展开后 XML 上限：64 MiB。
- 原始 `<programme>` 元素上限：200,000。
- 默认批次：最多 512 条且估算字段大小最多 1 MiB。
- `Content-Length` 已知且超过 32 MiB 时立即取消；未知长度在首次观察到 `totalBytesWritten` 超限时取消。
- Foundation 的进度回调是周期性的，因此不能证明其临时文件从未瞬时超过应用阈值。成功结果会再次以实际 `fstat` 长度验证，任何成功移交的文件一定不超过 32 MiB。
- 只接受 HTTP 200、无 `Content-Range`、无内容编码或 `identity` 内容编码；请求固定发送 `Accept-Encoding: identity`，不发送 Range。
- 最多 5 次重定向，允许 HTTP(S) CDN 跳转但拒绝 HTTPS 降级；跨来源时移除 Authorization 与 Proxy-Authorization。
- 无重试、无 Cookie、无 URLCache、无共享凭据存储。
- 错误不携带 URL、Header 或底层 transport 文本。

## 生命周期与竞态

- `didFinishDownloadingTo` 返回前只执行响应校验、`open` 和 `fstat`；文件读取与复制在独立 utility 队列完成。
- HTTP 完成、复制完成和取消通过一个锁保护的终态仲裁器汇合。
- 复制正在运行时，失败路径会先发出协作取消，再等待复制线程关闭其固定描述符，之后才清理 staging file。
- 只有 HTTP 成功、实际长度通过、复制成功且没有取消时，才调用一次 `finishAndTransfer()`。
- `XMLTVDownloadedFile` 是单次消费所有权；解析或显式 `release()` 后不能再次消费。
- 解析失败、sink 失败和取消继续沿用 9B.1/9B.2 的 tentative discard 语义。

## 自动测试

常规 `XMLTVDownloaderTests` 覆盖：

- 响应准入与已知长度。
- 非 200、`Content-Range`、gzip Content-Encoding、空编码、模糊 Content-Length、声明超限。
- 普通 XML 的网络到文件到批次解析。
- 无文件扩展名 gzip 的魔数识别与完整解析。
- 已知长度超限与未知长度超限均不能发布文件。
- 取消不能发布残缺文件。
- 显式释放和单次消费。

聚焦结果：8 passed，1 个显式 Release 回环门禁在普通测试中按设计 skipped，0 failed。

完整回归结果：

- OKVideoKit：878 passed，11 skipped，0 failed。
- macOS App 隔离 bundle identifier 测试：894 passed，9 skipped，0 failed。
- 使用隔离 bundle identifier 是为了避免桌面已安装正式 bundle 与测试宿主发生 LaunchServices 冲突；第一次正式 bundle identifier 运行只在启动测试宿主时失败，没有产生测试断言失败。

## 20 万节目 Release 回环门禁

工具：`Tools/SourceAudit/XMLTVDownloadProbe/run_9b3_chain.py`

原始证据：`/private/tmp/OKVideoMac-9B.agvNOL/9B3ChainFinal`

- 确定性节目数：200,000。
- 展开 XML：41,325,714 bytes。
- gzip 下载：1,262,796 bytes。
- gzip 全链路：3 个独立 Release XCTest 进程，全部通过完整节目摘要、输入字节和批次上限校验。
- RSS 增量：6.031、6.922、6.203 MiB；中位数 6.203 MiB。
- footprint 增量：3.953、4.844、4.125 MiB。
- 三次请求均为 `Accept-Encoding: identity`。
- 同一 41,325,714-byte 普通 XML 因超过 32 MiB 被拒绝；服务端记录连接在 2,359,296 bytes 时取消。
- Release XCTest 二进制 SHA-256：`7ba5dc8da069d82b2ff1c84a3b0682e2706fc5297712d18c859757da6d83f096`。
- 门禁脚本 SHA-256：`4f633367dbd6d7f56b79904f09dd91aa0b673d548b35faf087414905fba631fb`。

本结果只证明当前 macOS、当前 Foundation 实现和确定性回环样本下的应用链路。它不把 Foundation 内部缓冲解释成应用可严格控制的硬上限，也不替代后续真实 XMLTV 来源兼容验收。

## 下一阶段

下一步是 9C：将批次 sink 接入事务化 SQLite staging generation，完成失败回滚、成功原子激活、旧 generation 清理和按时间窗查询。9C 通过前，不把新下载器接入生产 `XMLTVService`，也不删除旧缓存回退路径。
