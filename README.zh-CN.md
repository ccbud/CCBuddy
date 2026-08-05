<div align="center">

<img src="docs/img/icon.png" alt="CC Buddy" width="120" height="120" style="border-radius: 26px; box-shadow: 0 12px 32px rgba(0,0,0,0.18);">

# CC Buddy

**集中管理与复盘已完成的 Coding Agent CLI 会话。**

[![Platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20Windows%20%C2%B7%20Linux-5b6cff?style=flat-square)](#安装) [![Built with Tauri](https://img.shields.io/badge/built%20with-Tauri-24C8DB?style=flat-square&logo=tauri&logoColor=white)](https://tauri.app/) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3b82f6?style=flat-square)](./LICENSE)

[下载](https://github.com/ccbud/ccbud/releases) · [English](./README.md) · **简体中文**

</div>

---

**CC Buddy** 是一个跨平台桌面应用，核心是管理和复盘本地 Coding Agent CLI 会话。它不替代 Agent 执行任务，而是把各 CLI 已写入本机的历史记录还原成可读、可搜索的时间线。任务结束后，你可以追踪目标、决策、工具调用、子代理、文件改动、失败点与最终结果。此外还附带可选的本地网关，用于转换模型 API。

```text
CLI 会话记录 ──▶ CC Buddy ──▶ 浏览 · 搜索 · 追踪 · 导出 · 复盘
```

## 会话复盘

支持读取 **Claude Code、Codex CLI、Qoder CLI、Grok Build CLI、GitHub Copilot CLI 和 Antigravity CLI** 的本地会话。

- **还原执行过程** —— 统一展示 Markdown、思考、工具调用与结果、补丁、图片、记录中包含的模型与 token 信息，以及主会话和子代理线程。
- **快速定位问题** —— 自动发现记录，按来源和项目归类，支持跨会话全文搜索与会话内搜索。
- **管理会话档案** —— 重命名、标签、筛选、回收站、自定义历史目录、活跃会话跟随，以及兼容的 JSONL/ZIP 导入。
- **继续发起复盘** —— 导出原始会话文件或打包记录（JSONL、ZIP 或 DB），也可导出独立 HTML；在 macOS 上可将主会话和子代理记录交给 Claude 或 ChatGPT 分析。

## 附带能力：本地 API 网关

作为附带能力，网关的客户端和上游均支持 **Anthropic Messages、OpenAI Chat Completions 和 OpenAI Responses**：协议相同则直通，不同则相互转换。它能一键配置 **Claude Code 和 Codex**；其他兼容客户端可手动使用本地端点。预设、自定义和插件服务均可切换并映射模型。

网关只监听 `127.0.0.1`；推理请求仍会发送给所选服务商。

## 安装

前往 [Releases](https://github.com/ccbud/ccbud/releases) 下载 macOS、Windows 或 Linux 最新版本。

Homebrew（仅 macOS）：

```bash
brew install --cask ccbud/tap/ccbud
```

## 开发

安装 Node.js 和 [Tauri 开发环境](https://v2.tauri.app/start/prerequisites/) 后：

```bash
git clone https://github.com/ccbud/ccbud.git && cd ccbud
npm install && npm start
```

## 许可证

基于 [GPL-3.0](./LICENSE) 协议开源。
