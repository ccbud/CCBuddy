# Settings Command Source Filter

设置页的「命令」分区按 CCbuddy Agent 来源管理用户自定义 slash command。

## 来源

- `ccbuddyAgent`: 用户命令目录为 `~/.ccbuddy/commands`，项目命令目录为 `<workspace>/.ccbuddy/commands`。
  迁移期服务层仍保留 `claudeCli`、`opencodeCli`、`geminiCli` 描述符，用于显式读取旧目录和测试旧文件格式，但 UI 不再暴露这些来源。未传 `agentSource` 时，所有读写都默认走 `ccbuddyAgent`。

## 文件格式

- `ccbuddyAgent` 使用 Markdown command 文件，支持 frontmatter 中的 `description` 和 `argument-hint`。
- 旧 `claudeCli`、`opencodeCli`、`geminiCli` 格式只保留显式兼容读取，不作为产品入口。

## Service 契约

`ICommandsService` 的 `list`、`writeCommandFile`、`updateCommandFile`、`deleteCommandFile` 和 `getPrimaryUserCommandsDirectory` 支持可选 `agentSource`。未传时默认使用 `ccbuddyAgent`，`list` 未传时只返回 CCbuddy Agent 命令。

`UserCommand.id` 包含来源、作用域和命令名，例如：

- `ccbuddyAgent:global:/review`

这样可以和历史 ID 保持区分，同时新 UI 只围绕 CCbuddy Agent 命令工作。
