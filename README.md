# CCbuddy

CCbuddy 是包含桌面、Web 和终端 Agent。它新增只读的本地会话查看器与跨项目日历时间线，用来复盘 Claude Code、Codex CLI、Qoder CLI、Grok Build、GitHub Copilot CLI 和 Antigravity CLI 已写入的历史。模型服务由用户自行配置，应用数据统一存放在 `~/.ccbuddy`。

旧版 CCbuddy 的网关、Provider 配置、插件和 Skills 管理、用量监控、会话修改、导入导出和续接功能没有迁入。历史查看器不修改任何生产者会话或 CLI 配置。底层 CCbuddy Agent 功能仍在工作台内。

首次启动后，在设置的模型服务商页面填写自己使用的服务地址和 API Key；默认可在本地工作区运行。远程工作区需要另行提供 CCbuddy 自有的运行时资源源，示例见 [.env.example](.env.example)。

## 开发

需要 Node.js 24.14.0 与 pnpm 10.33.2；版本以 [mise.toml](mise.toml) 为准。

```bash
pnpm install
pnpm bootstrap
pnpm dev:desktop:test
```

桌面应用菜单中的“历史会话”会在应用右侧主区域显示只读会话列表或时间线。Agent 工作台使用 CCbuddy 的现有运行时。Web 开发可运行 `pnpm dev:web`；终端 Agent 位于 [apps/ccbuddy-cli](apps/ccbuddy-cli)。完成 `pnpm bootstrap` 后，可在仓库根目录运行 `pnpm ccbuddy --version`；CLI 仅声明 `ccbuddy` 可执行命令。

## 检查

```bash
pnpm typecheck
pnpm lint
pnpm architecture:check --changed
```

会话行为、数据所有权和验收场景见 [历史查看规范](docs/specs/history-review.md)。四仓库关系及取舍见 [项目关系](docs/project-relationship.md)。

## 来源与许可

本重构以 CCbuddy 的 Apache-2.0 源码为底座；保留原 [LICENSE](LICENSE)、[NOTICE.md](NOTICE.md) 和 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。旧 CCbuddy 的 Swift 源码未复制进当前应用；其交互行为作为重写依据。Codex 和 Grok Build 的设计思想通过明确的只读协议、受限文件读取、可重建投影和有终态的刷新流程用于历史模块，未复制两者源码。
