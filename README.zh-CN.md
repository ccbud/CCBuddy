<div align="center">

<img src="docs/img/icon.png" alt="CC Buddy" width="120" height="120" style="border-radius: 26px; box-shadow: 0 12px 32px rgba(0,0,0,0.18);">

# CC Buddy

**集中管理与复盘已完成的 Coding Agent CLI 会话。**

[![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20silicon-5b6cff?style=flat-square&logo=apple&logoColor=white)](#安装) [![Built with SwiftUI](https://img.shields.io/badge/built%20with-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3b82f6?style=flat-square)](./LICENSE)

[下载](https://github.com/ccbud/ccbud/releases) · [English](./README.md) · **简体中文**

</div>

---

**CC Buddy** 是一个原生 macOS 桌面应用，核心是管理和复盘本地 Coding Agent CLI 会话。它不替代 Agent 执行任务，而是把各 CLI 已写入本机的历史记录还原成可读、可搜索的时间线。任务结束后，你可以追踪目标、决策、工具调用、子代理、文件改动、失败点与最终结果。此外还附带可选的本地网关，用于转换模型 API。

```text
CLI 会话记录 ──▶ CC Buddy ──▶ 浏览 · 搜索 · 追踪 · 导出 · 复盘
```

## 会话复盘

支持读取 **Claude Code、Codex CLI、Qoder CLI、Grok Build CLI、GitHub Copilot CLI 和 Antigravity CLI** 的本地会话。

- **还原执行过程** —— 统一展示 Markdown、思考、工具调用与结果、补丁、图片、记录中包含的模型与 token 信息，以及主会话和子代理线程。
- **快速定位问题** —— 自动发现记录，按来源和项目归类，支持跨会话全文搜索与会话内搜索。
- **管理会话档案** —— 重命名、标签、收藏、筛选、回收站、活跃会话跟随，以及兼容的 JSONL/ZIP 导入；会话目录在「设置 › 会话位置」管理。
- **接着做下去** —— 用各 CLI 自己的 resume 参数在 终端 / iTerm / Ghostty / Warp 中续上会话；导出原始会话文件或打包记录（JSONL、ZIP 或 DB），也可导出独立 HTML；也可把主会话和子代理记录交给 Claude 或 ChatGPT 分析。

## 附带能力：本地 API 网关

作为附带能力，网关的客户端和上游均支持 **Anthropic Messages、OpenAI Chat Completions 和 OpenAI Responses**：协议相同则直通，不同则相互转换。它能一键配置 **Claude Code 和 Codex**；其他兼容客户端可手动使用本地端点。内置约七十个服务商预设，也支持自定义与插件服务，均可切换并映射模型。

网关只监听 `127.0.0.1`；推理请求仍会发送给所选服务商。

## 安装

CC Buddy 2.x 支持 **运行 macOS 13 或更高版本的 Apple 芯片 Mac**。请前往 [Releases](https://github.com/ccbud/ccbud/releases) 下载已签名的 arm64 DMG。

2.x 是原生 Swift/SwiftUI 替代版本，不再发布 Intel Mac、Windows 或 Linux 构建。Releases 页面仍保留 1.x 历史产物，但这些平台不会收到 2.x 应用或更新通道。

Homebrew（Apple 芯片）：

```bash
brew install --cask ccbud/tap/ccbud
```

## 开发

原生开发需要 Xcode 26 与 XcodeGen；本地化和发布工具还会使用 Node.js。

```bash
git clone https://github.com/ccbud/ccbud.git && cd ccbud
brew install xcodegen
native/Scripts/fetch-bifrost.sh
xcodegen generate --spec native/project.yml --project native
xcodebuild -project native/CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS,arch=arm64' build
```

隔离运行单元/集成测试以及使用独立 Bundle ID 运行 UI 测试的命令见
[`native/README.md`](native/README.md)。独立 Bundle ID 可避免 XCTest 启动或终止已经安装的
CC Buddy 进程。

## 许可证

基于 [GPL-3.0](./LICENSE) 协议开源。
