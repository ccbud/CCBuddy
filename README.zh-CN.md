<div align="center">

<img src="docs/img/icon.png" alt="CC Buddy" width="120" height="120" style="border-radius: 26px; box-shadow: 0 12px 32px rgba(0,0,0,0.18);">

# CC Buddy

**集中管理与复盘已完成的 Coding Agent CLI 会话。**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20Universal-5b6cff?style=flat-square&logo=apple&logoColor=white)](#安装) [![Built with SwiftUI](https://img.shields.io/badge/built%20with-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-3b82f6?style=flat-square)](./LICENSE)

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

## 更快搜索，本地智能

- **内置 tgrep，移除自建会话 SQLite 数据库**：正文存入独立压缩的文件块。搜索不等待索引准备，先直接按块查找，tgrep 在后台就绪后缩小后续搜索的候选范围。精确核对 Unicode、摘要与消息位置，先显示可打开的命中，再补齐出现次数；面板呈现真实进度与延迟。[架构与真实历史实测](docs/search-performance.md)。
- **通过 Core ML 使用 Apple Neural Engine**：可选的智能排序用离线模型重新排列前 32 条结果，适合英文与代码查询。应用内置约 22.6 MB 的 MiniLM 权重，无需账号或额外下载。关键词结果先显示，模型准备期间依然可用，关闭智能排序即可恢复原顺序。Intel 使用 CPU 推理，含非拉丁文字的查询保留关键词排序。

在 Apple M4 的一次实测中，Core ML 计算计划为 155 个算子中的 147 个优选 ANE；三个候选向量已缓存时，新查询排序中位数为 0.774 ms，CPU 路径为 1.836 ms。界面会区分预期算子分配与实际硬件利用率计数。[模型说明与可复现测量](native/SEMANTIC_SEARCH.md)列出了完整条件、首次加载开销与语言限制。

## 焕新的 Mac 工作台

悬浮导航栏、分层搜索面板、更清晰的会话卡片与专注阅读，让会话库、正文和检查器各有位置。macOS 26 及以上使用原生玻璃效果；旧系统与辅助功能偏好使用材质或不透明回退。动效遵循「减少动态效果」，界面支持「降低透明度」与「增强对比度」。

按 **⌘K** 搜索，**↑ / ↓** 选择结果，**Return** 打开；**⌘⇧S** 切换专注阅读，**⌘1–6** 切换工作区，**⌘R** 更新会话索引，**⌘,** 打开设置。

这次改版沿着 macOS 27 的设计方向推进，实际使用带版本检查的 macOS 26 公开 API；应用不要求 macOS 27，也不宣称已在该系统完成验证。

## 附带能力：本地 API 网关

作为附带能力，网关始终接受客户端发来的 **Anthropic Messages、OpenAI Chat Completions 和 OpenAI Responses**，而上游由你在这三种协议中自行选配。

一个服务商只填一个根地址——`https://api.deepseek.com`——再在它下面按协议绑定最多三个地址：

| 协议 | 地址 |
| --- | --- |
| Anthropic Messages | `https://api.deepseek.com/anthropic` |
| OpenAI Chat Completions | `https://api.deepseek.com/chat/completions` |
| OpenAI Responses | `https://api.deepseek.com/responses` |

- **三个都绑**：每个客户端都会被交给协议相同的那个地址，原样直通，不做任何转换。服务商自己就支持三种协议时，网关不会白做一次转换。
- **只绑一个或两个**：协议已绑定的客户端照样直通；协议未绑定的客户端由网关完成协议转换后再发出。转换是按你实际配置了什么来决定的，不是提前写死的。

两种情况下，若某个上游失败，队列中的其余上游都会按顺序接管。它能一键配置 **Claude Code 和 Codex**；其他兼容客户端可手动使用本地端点。内置预设覆盖 Anthropic、OpenAI、Google 以及提供官方 Coding 端点的模型厂商，也支持自定义与插件服务，均可切换并映射模型。若服务商提供 `/v1/models` 或 `/models`，可在编辑器中一键拉取并自动建立模型绑定；没有该接口时按钮会置灰而不是报错。

网关只监听 `127.0.0.1`；推理请求仍会发送给所选服务商。

## 安装

CC Buddy 2.x 支持 **运行 macOS 13 或更高版本的 Apple 芯片与 Intel Mac**。请前往 [Releases](https://github.com/ccbud/ccbud/releases) 下载已签名的 Universal DMG，其中同时包含 arm64 与 x86_64。

2.x 是原生 Swift/SwiftUI 替代版本，不再发布 Windows 或 Linux 构建。Releases 页面仍保留 1.x 历史产物，但这些平台不会收到 2.x 应用或更新通道。

Homebrew：

```bash
brew install --cask ccbud/tap/ccbud
```

## 开发

原生开发需要 Xcode 26、XcodeGen、Python 3，以及通过 [rustup](https://rustup.rs/) 安装的当前 Rust stable 工具链；本地化和发布工具还会使用 Node.js。安装好的应用无需这些开发工具。

```bash
git clone https://github.com/ccbud/ccbud.git && cd ccbud
brew install xcodegen
native/Scripts/fetch-bifrost.sh
bash native/Scripts/build-tgrep.sh
python3 native/Scripts/verify-semantic-model.py
xcodegen generate --spec native/project.yml --project native
xcodebuild -project native/CCBuddy.xcodeproj -scheme CCBuddy \
  -destination 'platform=macOS' build
```

辅助脚本默认构建当前 Mac 的架构，发布构建同时打包 arm64 与 x86_64。无需本机存在 tgrep 源码目录，Cargo 会使用固定的上游版本与依赖锁文件。

### 正式发布

任何推送到 `main` 的提交（包括 PR 合并与直接 push）都会触发正式发布流水线，不再需要手动打标签。流水线为该次提交创建只修改版本字段的不可变发布快照，自动分配下一个补丁版本，并生成 annotated tag；`main` 本身不会被机器人版本提交反复改写。

同一次工作流随后完成共享测试、原生单元/UI 测试、Universal 打包、Developer ID 签名与 Apple 公证，再一次性公开包含 DMG、更新压缩包、签名和 `latest.json` 的 GitHub Release。测试通过但发布阶段失败时不会提前公开不完整产物；在 Actions 重跑失败任务即可继续。

重复执行同一提交会复用原标签，不创建额外版本。连续推送进入串行队列（GitHub 上限为 100 个等待任务）；较旧提交即使晚完成也不会覆盖最新更新通道或 Homebrew。手动推送合法的 `vX.Y.Z` 标签仍受支持。[发布工作流](.github/workflows/release.yml)

Universal 构建、隔离单元/集成测试，以及使用独立 Bundle ID 运行 UI 测试的命令见[原生开发指南](native/README.md)。[架构说明](docs/architecture.md)介绍原生模块、数据流与兼容边界。

## 许可证

基于 [GPL-3.0](./LICENSE) 协议开源。
