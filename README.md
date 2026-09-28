# PlanWatch

一个只监控 coding 订阅额度的 macOS 菜单栏小工具。原生 SwiftUI 界面，适用于 **macOS 14+，Apple Silicon / Intel**。

- 点击菜单栏查看 Codex、Kimi Code、Command Code 和 OpenCode Go 的额度。
- 五小时、周、月进度条，重置倒计时；缺失数据明确显示“未提供”。
- 默认每两分钟刷新，失败退避，唤醒后刷新。
- 已用 80%、95%、100% 时发送系统通知；重启后保留去重记录。
- 凭证存放在 macOS 钥匙串；不需要外部服务或数据库。

## 在 Mac 上构建并安装

需要 Xcode Command Line Tools（Swift 5.9+）和 Go 1.22+：

```sh
xcode-select --install
brew install go
cd planwatch
bash scripts/build-mac.sh
```

脚本先运行测试，再生成 `dist/PlanWatch.app` 和支持 Intel / Apple Silicon 的 `dist/PlanWatch-mac-universal.zip`。将应用拖入 **Applications** 后打开，菜单栏会出现仪表图标。

仓库包含 GitHub Actions 的 macOS 构建工作流，运行成功后可从该次工作流的 Artifacts 下载应用；本项目不会自动发布 Release。

本地构建使用临时签名，没有 Apple 公证。分发给其他 Mac 的下载包可能需要在系统设置 → 隐私与安全性中允许打开。可通过 `PLANWATCH_SIGN_IDENTITY` 指定自己的 Developer ID；脚本不包含公证上传。

## 接入账号

在菜单栏面板右下角打开设置。

| 服务 | 接入方式 | 可查询内容 |
| --- | --- | --- |
| Codex | 在本机安装 Codex CLI 并执行 `codex login`；自动查找或手动选择可执行文件 | 官方 App Server 返回的所有额度池及窗口；不假设 primary 一定为五小时 |
| Kimi Code | 网页登录，或粘贴 Kimi Code 控制台的 API Key；选择中国区或国际区 | 网页会话可补全共享会员月总额度；API Key 支持新版 ratio pools 和旧版 counters。接口缺失时显示未提供 |
| Command Code | 在内置网页登录并点击“完成登录并连接”；也支持手动保存 Cookie | 五小时和周 credits；月余额、月总量、账期。充值余额与订阅额度分开 |
| OpenCode Go | 粘贴 Go API Key | usage API 返回的五小时、周、月汇总；仅在接口明确返回 models 时显示模型明细 |

Kimi 普通 Moonshot API Key、OpenAI API Key 不能替代对应 coding 订阅。Command Code 的查询依赖其控制台内部接口，登录过期后需重新登录。如果第三方 OAuth 不允许内嵌浏览器登录，使用账号设置里的 Cookie 备用入口。

在“提醒与显示”中开启系统通知。可发送测试通知，并选择登录 Mac 时启动、刷新频率和菜单栏剩余百分比。macOS 专注模式、通知设置、电脑休眠会影响通知展示。应用退出或电脑休眠时不会采集。

首次读数已经超过阈值也会提醒；一次跨越多个阈值只发送最高级别。接口返回的重置时间已过去时，不对旧窗口提醒。滚动窗口通过连续低用量读数和冷却时间重新启用提醒。

## 数据与隐私

- 凭证：Keychain service `app.planwatch.credentials`。
- 设置、上次成功快照、提醒状态：`~/Library/Application Support/PlanWatch/`。不保存 API Key / Cookie 到这些 JSON 文件。
- 内置 Kimi / Command Code 登录页使用该应用的 WebKit 数据目录；移除账号会清除对应网站的登录会话。
- 采集组件通过标准输入接收凭证，不放入命令行参数，不输出服务端原始错误正文。
- 查询固定的服务商 HTTPS 地址，拒绝 HTTP 重定向携带凭证。仅执行查询，不调用模型、充值或修改套餐。
- 账号切换会清除本工具对应快照及提醒状态；Codex 通过返回的账号标识区分提醒。

## 开发与验证

```sh
cd collector
go test -race ./...
go vet ./...
# 在 Mac 上，从仓库根目录：
swift test
bash scripts/build-mac.sh
open dist/PlanWatch.app --args --demo
```

`--demo` 是明确标注的界面演示模式，不查询账号、不发送通知、不写配置。

SwiftUI 负责界面、钥匙串、登录项及系统通知；一个无第三方依赖的 Go 小组件负责查询和解析，随应用打包。安装后的用户不需要 Go。组件采用标准输入/输出 JSON，不开放端口，也不启动后台网络服务。

### 当前验证边界

开发环境为 Linux：Go 采集测试与 Mac 采集组件交叉编译可在此验证。SwiftUI、macOS 钥匙串、WebKit 登录、登录项和系统通知需要在 Mac 上完成构建及实机验证。测试使用脱敏的协议示例；尚未使用你的四家账号进行在线验收。新旧套餐和内部接口可能有差异，未知字段不会被当成 0% 或无限额度。

Mac 验收步骤：

1. 构建脚本与 Swift 测试通过，打开应用可看到菜单栏与演示面板。
2. 接入每个账号，将读数及重置时间逐项对照官方控制台。
3. 开启通知并发送测试；验证 macOS 通知权限与专注模式。
4. 断网后保留上次成功数据并标记“待更新”；恢复网络后可刷新。
5. 退出重开后配置仍在；睡眠唤醒后自动刷新；登录项可开关。

接口依据及兼容范围见 [docs/providers.md](docs/providers.md)。
