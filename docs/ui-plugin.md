# UI Plugin 与 Gen UI：能力、页面 API 与宿主调试

产品规则与验收见 [规范](specs/plugin-ui-and-gen-ui.md)。本文面向插件作者和宿主联调。

## UI Plugin 能做什么

UI Plugin 给普通插件增加可交互页面。Agent 调用工具创建或修改内容，用户直接操作画布、表单、文件列表，再把选区或操作结果交回对话。页面通过 MCP Apps 与宿主通信，业务数据由插件的 MCP 服务管理。注册、安装、启用和更新沿用普通插件流程；页面使用官方 `@modelcontextprotocol/ext-apps`（宿主锁定 `2.0.0`），不需要单独的 SDK。

| 能力               | 用户看到的效果                               | 开发入口                                         |
| ------------------ | -------------------------------------------- | ------------------------------------------------ |
| 工具结果带交互页面 | 生成画板、展示图表、填写表单                 | MCP 工具 `_meta.ui.resourceUri` + HTML 资源      |
| 会话侧栏面板       | 手动打开编辑器，后续工具继续操作同一份文档   | 清单 `ui.surfaces`，工具 `_meta.ui.surface`      |
| 页面调用插件服务   | 点击按钮刷新数据、保存文档、执行操作         | `app.callServerTool()`                           |
| 页面与主对话协作   | 引用选区，或由用户点击发送下一条消息         | `updateModelContext()` / `sendMessage()`         |
| App 内模型调用     | 回答留在插件自己的界面                       | `createSamplingMessage()`                        |
| 模型调用页面工具   | 操作只有活页面才拥有的编辑器状态             | `registerTool()` 或 `onlisttools` + `oncalltool` |
| 页面状态与资源更新 | 切换位置保留页面，重建恢复视图，订阅服务变化 | 活页面保留、widgetState、资源订阅                |

交互页面只用于 **CCbuddy Desktop 的本地工作区**。Web、手机和远程工作区保留普通 MCP 工具记录。插件页面与 Gen UI 的加载和通信协议不同，不能混用两者的 API。

## Gen UI：按需生成可交互的回答

Gen UI 让 Agent 针对当前问题生成 HTML / JavaScript 页面，直接嵌入对话：拖动滑块、切换条件、勾选项目，观察结果，再带着当前参数继续提问。页面按需生成，不需要先创建和安装插件。内置的 `visualize` 插件提供作者指引、样式和受限的 `window.ccbuddy` 桥；Agent 生成交互视图前会先加载这个 skill。

| 能力       | 当前行为                                                                                   |
| ---------- | ------------------------------------------------------------------------------------------ |
| 对话内交互 | 页面随回答完成后展示，可包含图表、表单、模拟器和轻量原型                                   |
| 展开与分享 | 可以展开预览、收起，并复制当前界面为图片；展开和收起保留同一个活页面                       |
| 状态与追问 | 页面可保存控件状态，并在用户触发后发送后续问题；仅调整控件或保存状态不会自动启动 Agent     |
| Tweak 调整 | 页面注册控件后，宿主提供滑块、颜色、开关和选项等调整入口，支持重置、原始效果预览和明确提交 |

生成页面使用宿主注入的接口：

| 接口                                                              | 用途                                                                                  |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `window.ccbuddy.widgetState`                                      | 读取已保存的页面状态，初始值可能为 `null`                                             |
| `window.ccbuddy.setWidgetState({ modelContent, privateContent })` | 替换整个 JSON 状态快照，合计不超过 16 KiB；只有 `modelContent` 会进入下一轮模型上下文 |
| `window.ccbuddy.sendFollowUpMessage({ prompt, title })`           | 发送后续问题，`title` 可选；没有有效用户操作时需要确认，失效或只读会话不能发送        |
| `ccbuddy:set_globals`                                             | 监听状态或主题更新，从事件的 `detail.globals` 读取新值                                |

桌面端向 Agent 提供当前会话的专用输出目录（`~/.ccbuddy/v2/visualizations/<scope>`）。生成的 HTML 保存在该目录，由宿主加载，不写入项目工作区；页面状态按工作区和会话隔离。Gen UI 页面不提供 `callTool`、MCP 资源读取、Node 或任意文件访问；需要插件服务执行操作时使用 UI Plugin。

### Gen UI 与 UI Plugin 怎么选

| 对比项   | Gen UI                                           | UI Plugin                                           |
| -------- | ------------------------------------------------ | --------------------------------------------------- |
| 来源     | Agent 围绕当前问题即时生成页面                   | 开发者维护和发布插件，用户安装、启用                |
| 适合什么 | 概念讲解、交互图表、模拟器、临时计算器和界面原型 | 持续使用的编辑器、文件工具和带业务数据的应用        |
| 页面能力 | Gen UI 状态、追问与 Tweak 接口                   | MCP Apps API、插件 MCP 工具与资源，遵循宿主支持范围 |
| 数据归属 | 宿主管理生成文件和会话页面状态                   | 插件服务管理业务文件或数据库，页面管理视图          |

实现与页面示例：[Gen UI 契约](../packages/ui/src/gen-ui/CONTRACT.md)、[页面 API 示例](../apps/ccbuddy-cli/packages/visualize-plugin/skills/visualize/references/api.md)、[Tweak 指南](../apps/ccbuddy-cli/packages/visualize-plugin/skills/visualize/tweak.md)。

## 给自己的插件接入 UI

沿用普通插件的安装目录与市场条目；需要编译的源码包声明自己的 `build`，额外资源使用可选 `stage`。下面是安装清单 `.ccbuddy-plugin/plugin.json` 的最小页面示例：

```json
{
  "name": "my-panel",
  "version": "0.1.0",
  "description": "我的交互面板",
  "mcpServers": {
    "app": {
      "type": "stdio",
      "command": "node",
      "args": ["${CCBUDDY_PLUGIN_ROOT}/dist/server.mjs"],
      "cwd": "${CCBUDDY_PROJECT_DIR}",
      "env": {
        "CCBUDDY_WORKSPACE_ROOT": "${CCBUDDY_PROJECT_DIR}",
        "CCBUDDY_PLUGIN_DATA": "${CCBUDDY_PLUGIN_DATA}"
      }
    }
  },
  "ui": {
    "surfaces": [
      {
        "id": "editor",
        "title": { "en": "Editor", "zh-CN": "编辑器" },
        "server": "app",
        "resourceUri": "ui://my-panel/editor.html",
        "availability": "session"
      }
    ]
  }
}
```

服务端需要实际注册 `ui://my-panel/editor.html` 资源并返回 `text/html;profile=mcp-app`。让工具结果使用该面板时，在工具定义中设置 `_meta.ui.resourceUri` 和 `_meta.ui.surface: "editor"`；`_meta.ui.visibility: ["model", "app"]` 允许模型与页面调用，仅页面工具使用 `["app"]`。`ui.surfaces` 可省略，此时仍可通过工具元数据提供内联页面。

插件文件使用 `${CCBUDDY_PLUGIN_ROOT}` 定位，工作区文件操作使用 `${CCBUDDY_PROJECT_DIR}`，持久数据使用 `${CCBUDDY_PLUGIN_DATA}`。用户配置通过清单 `userConfig` 定义，并在服务配置里用 `${user_config.<key>}` 引用。页面通过服务执行文件操作，不直接访问主应用源码或 Node API。

## 页面 API 速查

以当前宿主实现和锁定的 SDK 类型为准。先注册事件，再 `connect()`；连接后读取 `getHostCapabilities()`，按返回的能力启用功能。

### 官方 MCP Apps API

| API / 事件                                                      | 用途                                 | CCbuddy 行为与注意事项                                                                        |
| --------------------------------------------------------------- | ------------------------------------ | --------------------------------------------------------------------------------------------- |
| `new App(info, capabilities, options)`、`connect()`             | 创建页面连接并完成握手               | 每个活页面只建一个 App；不要同时访问会触发另一连接的 `window.ccbuddy`                         |
| `getHostVersion()`、`getHostCapabilities()`、`getHostContext()` | 读取宿主、能力、主题、语言和展示模式 | 在连接完成后使用；不要只按宿主版本号猜能力                                                    |
| `ontoolinput`、`ontoolresult`、`ontoolcancelled`                | 接收完整输入、结果和取消             | 大 UI 延迟加载时，保留初始结果再交给 UI，避免丢通知                                           |
| `onhostcontextchanged`                                          | 响应主题、语言、尺寸或模式变化       | 更新显示；不要因此重复执行业务操作                                                            |
| `callServerTool({ name, arguments }, options)`                  | 调用当前插件服务的工具               | 沿用 Agent 的权限和审批；`options.signal` 可取消；返回真实 `CallToolResult`                   |
| `readServerResource({ uri })`                                   | 读取当前服务的资源                   | 返回 MCP `contents`；二进制是 base64；不能用它访问其他插件或任意本地文件                      |
| `listServerResources({ cursor })`                               | 分页列出服务资源                     | 资源模板列表用后表中的 `resources/templates/list` 请求                                        |
| `sendMessage({ role: "user", content })`                        | 发出主对话后续消息                   | 需要 `message` 能力；有用户手势时发送，无手势时进入确认流程                                   |
| `updateModelContext({ content, structuredContent })`            | 给下一轮对话附加选区等上下文         | 需要 `updateModelContext` 能力；在输入区可见、可删，不立即发消息，不是持久存储                |
| `createSamplingMessage(params, { signal })`                     | App 内调用当前任务模型               | 需要 `sampling` 能力；支持文本与符合限制的图片输入，返回文本；对话历史由 App 提供             |
| `registerTool(name, config, handler)`                           | 页面提供可被模型调用的工具           | 握手前登记；声明 App 的 `tools` 能力；随活页面登记/撤销并遵守既有审批                         |
| `onlisttools`、`oncalltool`、`sendToolListChanged()`            | 手动管理页面工具目录                 | 另一种页面工具实现方式；取消信号在回调 `extra.mcpReq?.signal` 中                              |
| `requestDisplayMode({ mode })`                                  | 请求切换展示位置                     | `inline` 为内联，`fullscreen` 为侧栏；以返回模式为准；`pip` 当前保持原模式                    |
| `sendSizeChanged({ height })`                                   | 报告内容高度                         | 可用 SDK 自动测量；手动测量内容容器，避免把视口高度反馈给宿主                                 |
| `openLink({ url })`                                             | 通过宿主打开外链                     | 仅允许 `http:` / `https:`                                                                     |
| `downloadFile({ contents })`                                    | 调用原生保存对话框                   | 需要 `downloadFile` 能力；支持嵌入资源或当前服务的资源链接；取消/写入失败返回 `isError: true` |
| `sendLog({ level, data })`                                      | 发送可观察的页面诊断                 | 不向 stdio 服务的 stdout 写调试日志；不要记录密钥或用户内容                                   |
| `onteardown`                                                    | 释放页面监听器等资源                 | 宿主做有时限的 teardown，不应把唯一保存操作留到此时                                           |
| `requestTeardown()`                                             | 请求宿主释放页面                     | 当前只记录请求；实际生命周期跟随卡片/面板，不能把它当关闭按钮                                 |

Sampling 使用接纳请求时的任务模型（用户自行配置的模型服务），不读取主聊天历史；只有 App 明确传入的历史进入请求。当前不接受 `temperature`、`tools`、原生 audio 等未实现参数，`includeContext` 只支持 `none`。回答和取消不会被自动追加为主对话回合。

### CCbuddy 扩展与低层 MCP 请求

`app.request()` 是官方 App 的低层接口，结果用 `@modelcontextprotocol/core` 的对应 schema 校验。

| 接口 / 字段  | 调用或声明方式                                                                            | 适用范围                                                                                                                |
| ------------ | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 会话视图状态 | `ui/set-widget-state`，参数 `{ widgetState }`，结果 `EmptyResultSchema`                   | 先检查 `experimental["ccbuddy/widgetState"]`；初值来自 hostContext 同名键；仅宿主内存，会话内重建可恢复，应用重启不保证 |
| 资源模板列表 | `resources/templates/list`，结果 `ListResourceTemplatesResultSchema`                      | 当前服务的 MCP 模板目录；不要假定 App 存在 `listServerResourceTemplates()` 便捷方法                                     |
| 资源订阅     | `resources/subscribe` / `resources/unsubscribe`，参数 `{ uri }`，结果 `EmptyResultSchema` | 先检查 `experimental["ccbuddy/resourceSubscribe"]`；服务端也须支持订阅                                                  |
| 资源变更通知 | `notifications/resources/updated` / `notifications/resources/list_changed`                | 先用 `setNotificationHandler()` 注册处理器；收到 URI 后自行重新读取资源                                                 |
| 当前侧栏面板 | `app.getHostCapabilities()?.experimental?.["ccbuddy/surface"]` 返回 `{ id }`              | 清单 `ui.surfaces[].id` 与工具 `_meta.ui.surface` 保持一致                                                              |
| CSP 放宽     | 资源 `_meta["ccbuddy/csp"]` 中 `unsafeEval`、`wasmUnsafeEval`                             | 检查 `experimental["ccbuddy/csp"]` 返回的支持标记；不等于获得文件或网络权限                                             |

### 现有 `window.ccbuddy` 页面

已有兼容页面可以继续使用以下别名；新页面优先使用官方 App，两种连接方式选一种即可。

| 类别           | 可用成员                                                                                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 连接与观察     | `ready()`、`subscribe(listener)`，后者返回取消订阅函数                                                                               |
| 输入与宿主信息 | `toolInput`、`toolOutput`、`toolResponseMetadata`、`toolCancelled`、`hostInfo`、`hostCapabilities`、`hostContext`、`protocolVersion` |
| 展示信息       | `theme`、`locale`、`displayMode`、`maxHeight`、`safeArea`、`userAgent`                                                               |
| 工具与资源     | `callTool(name, args)`、`readResource(uri)`、`listResources()`、`listResourceTemplates()`                                            |
| 资源订阅       | `subscribeResource(uri)`、`unsubscribeResource(uri)`、`onResourceUpdated(listener)`、`onResourceListChanged(listener)`               |
| 会话视图状态   | `widgetState`、`setWidgetState(state)`                                                                                               |
| 对话协作       | `sendFollowUpMessage({ prompt, structuredContent })`、`updateModelContext({ content, structuredContent })`                           |
| 展示与文件     | `requestDisplayMode({ mode })`、`notifyIntrinsicHeight(height)`、`openExternal({ href })`、`downloadFile(contents)`                  |

别名没有 sampling 或页面工具的便捷接口；需要这些能力时使用官方 App。`openExternal` 的参数叫 `href`，官方 `openLink` 的参数叫 `url`，不要混用。

### 最小页面连接示例

```ts
import { App } from "@modelcontextprotocol/ext-apps";
import { EmptyResultSchema } from "@modelcontextprotocol/core";

const app = new App(
  { name: "my-panel", version: "0.1.0" },
  { availableDisplayModes: ["inline", "fullscreen"] },
);
let latestResult: unknown;
app.ontoolresult = (result) => {
  latestResult = result.structuredContent;
  document.querySelector("pre")!.textContent = JSON.stringify(latestResult);
};
function applyTheme() {
  document.documentElement.dataset.theme = app.getHostContext()?.theme ?? "light";
}
app.onhostcontextchanged = applyTheme;
await app.connect();
applyTheme();

async function saveViewState(state: unknown) {
  if (!app.getHostCapabilities()?.experimental?.["ccbuddy/widgetState"]) return;
  await app.request(
    { method: "ui/set-widget-state", params: { widgetState: state } },
    EmptyResultSchema,
  );
}
```

这段代码只处理通信，文档保存仍通过插件服务执行。

## 平台、数据与能力边界

| 数据 / 能力                      | 应放在哪里或如何使用                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------ |
| 业务文档、清理计划、场景版本     | 插件服务持有；文件或数据库写入插件数据目录，按业务规则确认和恢复                           |
| 当前活页面输入、滚动和运行中请求 | 同一活页面切内联/侧栏时保留；不重复连接或重发请求                                          |
| `widgetState`                    | 临时界面快照；重建、手动重试与进程重启的语义不同，不能用来承诺永久保存                     |
| localStorage / IndexedDB         | 稳定来源下的浏览器存储，可跨进程；按插件身份/工作区隔离，"清除所有数据"会一并清掉          |
| 网络、字体、WASM、脚本           | 优先随包提供；外部访问受资源 CSP 限制，页面没有 Node 或任意文件系统访问权                  |
| 原生权限                         | camera / microphone / geolocation / clipboardWrite 需资源声明及宿主/系统授权；不是默认可用 |

HTML 资源上限 **16 MiB**，页面资源读取上限 **8 MiB**。初始工具结果限制：`structuredContent` 64 KiB、页面元数据 16 KiB、`content` 32 KiB；超限字段会被省略并标记，页面应从服务重新读取完整数据。尚未实现：纯图片/资源链接的完整消息内容扩展、App 工具双向进度。

## 宿主开发与调试

1. `pnpm dev:desktop` 启动宿主；宿主不会自动注册插件。
2. 把插件目录做成本地市场后用 CLI 装进同一份配置（`--scope user`），或在桌面 **插件市场 → 新增** 里添加该目录：

   ```sh
   pnpm ccbuddy plugins marketplace add /path/to/local-marketplace --scope user
   pnpm ccbuddy plugins install my-panel@<来源名> --scope user
   pnpm ccbuddy plugins enable my-panel@<来源名> --scope user
   ```

   修改插件代码后刷新来源并重装：刷新只更新目录，重装才更新代码副本。之后重启桌面实例，在新会话里验证。

3. 验证入口：

   | 层次         | 命令                                                                                                        |
   | ------------ | ----------------------------------------------------------------------------------------------------------- |
   | 静态检查     | `pnpm typecheck`、`pnpm lint`、`pnpm fmt:check`、`pnpm architecture:check --changed`                        |
   | 模块单测     | 根目录 `pnpm exec vitest run <文件>`；`packages/ui` 内的测试在该目录下运行以启用 `@/` 别名                  |
   | Gen UI 桌面  | `pnpm --dir packages/desktop exec vite build && node packages/desktop/scripts/gen-ui-e2e.mjs`               |
   | 插件页面桌面 | `node packages/desktop/scripts/mcp-apps-host-e2e.mjs`，可加 `--managed-only` 等模式或 `--reuse-agent-build` |

   桌面 fixture 使用临时 profile 与本地模型 fixture，末尾输出结果目录。

常见问题：

| 现象                       | 先检查                                                                                                                           |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| 已登记来源，侧栏仍没有面板 | `plugins list --json` 的安装/启用状态；当前是否是桌面本地工作区；清单的 `ui.surfaces` 是否引用正确 `mcpServers` 键和 `ui://` URI |
| 修改代码后还是旧页面       | 是否刷新同一来源并重装目标插件；是否仍运行旧实例或旧会话                                                                         |
| 面板打开但资源失败         | 安装目录是否有 `dist`、离线字体/脚本/WASM；检查 CSP 与资源读取上限                                                               |
| 握手两次或初始画布为空     | 是否创建了两个 App，或官方 App 与 `window.ccbuddy` 混用；是否在连接前安装事件处理器并保留初始结果                                |
| 点击"引用"没有立刻发消息   | `updateModelContext` 是给下一轮添加上下文，发消息用 `sendMessage`；检查输入区的插件上下文                                        |
| sampling 不可用或参数被拒  | 宿主是否声明 `sampling`，当前任务是否可操作，参数是否属于支持子集                                                                |
| 开发者工具没有页面日志     | 先看应用"帮助 → 开发者工具"里的宿主错误；插件有独立 guest，优先用 `app.sendLog()` 采集自己的日志                                 |

stdio MCP 服务的 stdout 只输出协议消息，调试日志写 stderr。

## 宿主源码导航

| 排查目标                          | 当前源码入口                                                                                                                                                                                             |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 能力声明                          | [buildPluginUiHostCapabilities.ts](../packages/ui/src/plugin-ui/domain/buildPluginUiHostCapabilities.ts)                                                                                                 |
| 会话消息、上下文和 widgetState    | [pluginUiInteractionPorts.ts](../packages/ui/src/plugin-ui/app/pluginUiInteractionPorts.ts)                                                                                                              |
| 工具、外链和展示模式              | [pluginUiHostAppHandlers.ts](../packages/ui/src/plugin-ui/app/pluginUiHostAppHandlers.ts)                                                                                                                |
| 资源订阅                          | [pluginUiResourceSubscriptions.ts](../packages/ui/src/plugin-ui/app/pluginUiResourceSubscriptions.ts)                                                                                                    |
| 页面保留、回收与恢复规则          | [plugin-ui/CONTRACT.md](../packages/ui/src/plugin-ui/CONTRACT.md)                                                                                                                                        |
| HTML、资源与 Host 边界            | [plugin-ui-bridge/CONTRACT.md](../packages/services/src/plugin-ui-bridge/CONTRACT.md)                                                                                                                    |
| Electron 沙箱与浏览器存储         | [pluginSandbox/CONTRACT.md](../packages/desktop/src/main/pluginSandbox/CONTRACT.md)                                                                                                                      |
| API 限额、sampling 参数与别名类型 | [MCP Apps 契约](../packages/shared/src/mcp-apps/contract.ts)、[sampling.ts](../packages/shared/src/mcp-apps/sampling.ts)、[aliasApi.ts](../packages/desktop/src/renderer/src/plugin-sandbox/aliasApi.ts) |
| Gen UI 契约与输出目录             | [gen-ui/CONTRACT.md](../packages/ui/src/gen-ui/CONTRACT.md)、[genUiPaths.ts](../packages/shared/src/node/genUiPaths.ts)                                                                                  |
| 桌面集成测试                      | [gen-ui-e2e.mjs](../packages/desktop/scripts/gen-ui-e2e.mjs)、[mcp-apps-host-e2e.mjs](../packages/desktop/scripts/mcp-apps-host-e2e.mjs)                                                                 |
