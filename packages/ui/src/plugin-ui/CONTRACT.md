# plugin-ui

Renderer 模块，层序 `domain → app → adapters → components`；公开入口为 `index.ts`。

- 窗口唯一页面管理器统一管理 MCP 与 Gen UI 的容量和回收；`createPage` 持有 MCP controller、AppBridge、独立 workspace/session lease、通知 feed 和内存快照。卡片、侧栏只登记锚点。内联页面位于滚动容器内部，侧栏单独定位；原子移动保留同一 guest，不重读资源、不重新握手。解绑必须在 DOM 卸载前同步移入隐藏承载区。
- 逻辑键包含 workspace identity（本地 fallback 为路径）、session、plugin、server、resource 和逻辑视图。surface 显式共享；普通工具只按明确的 widgetSessionId 与相同权限范围共享，否则按 toolCallId 隔离。禁止同回合同资源推断合并。
- UI 不接触插件 HTML、数据库和连接凭据。经 `IPluginUiBridgeService` 获取句柄，平台端口只校验 sandboxId/initId；请求与 live 通知绑定 Agent runtimeId/generation/token/appIdentity。
- 官方 ext-apps 2.0.0 每活页面一个 AppBridge；握手期限 15 秒。保留 `experimental["ccbuddy/…"]` 的 widgetState、resourceSubscribe、surface、CSP 扩展；不模拟完整 OpenAI API。
- App-provided tools 在 initialized 后发现与登记；认领后用官方 SDK AbortSignal 执行，模型取消沿 live-only delta 到页面。callId 去重，终态结果不可再写入。页面调用 MCP 的目标由宿主固定，复用 Agent 的权限和审批路径，原始结果直接返回。
- 页面 `availableDisplayModes` 是硬约束；inline/fullscreen 对应内联/侧栏，pip 保持当前模式。高度默认 240px、范围 [80,1200]，hostContext 只回传 width/maxHeight，避免高度回环。布局按帧合并。
- widgetState 仅接受页面主动提交，唯一内存 store 按逻辑键隔离；重建时在 `hostContext["ccbuddy/widgetState"]` 下发。切位置不复制；手动重试、任务淘汰、来源撤销清除；应用重启为空。
- 连续离屏 5 分钟回收活页面；侧栏展示或有审批/调用时不回收。Agent 原子确认空闲后才释放。最多 30 个任务和 64 个活页面，容量 admission 串行；无法安全回收时返回错误。任务删除同时取消排队创建。
- 已获准的主动释放先按原 sandboxId 解除导航/崩溃监听，避免 Main 停止页面的 about:blank 导航误报崩溃；真实运行中的导航/崩溃仍进入 error，重试后重建。
- 释放顺序：失效凭证、取消调用和登记、有界 resource-teardown、关闭端口/guest、释放 feed/lease。迟到 prepare、注销和锚点清理只作用于捕获的原实例。卡片卸载不切断保活页面的订阅。
- `sendFollowUpMessage` 仍走既有会话动作和手势/可编辑确认；确认完成后验证实例。只读会话不登记动作。`updateModelContext` 只投递到该 workspace/session 的 composer，不是数据库状态。
- `display.ui` 无效、Web/手机/远程、不支持平台或初始化失败继续普通 MCP 卡回退。工具行替代与折叠策略仍由投影派生；不会另建 accepted-input queue 或改变 continuous/replayable 语义。
- 工具失败、取消或 `display.ui.isError` 只保留普通工具记录，不占用 inline/侧栏区域、不自动开侧栏，手动固定/showInline/最近回合不能越过此门禁；失败不替代已有成功页面。原始错误结果及页面通知语义保持不变。
- 工具行裁决与手动固定由 `pluginUiInstanceStore` 的同一会话条目持有，统一使用 `buildPluginUiSessionKey`。时间线挂载持独立 lease，最后一次幂等释放后才进入闲置 LRU；最多保留 30 个闲置会话，挂载中的会话不淘汰。写入、挂载、最后释放更新活跃顺序，读取无副作用。页面 owner 移除任务时请求清理：有 lease 则标记待清理并保留现有裁决和 pins，直到最后一次释放后直接删除，不进入 LRU；没有 lease 则立即删除。实际清理时同时释放裁决与 pins 并通知订阅；重复请求/释放幂等，旧 lease 不得清理同 key 的新条目。返回未淘汰会话保留手动偏好，淘汰后重新派生并恢复默认折叠。此缓存不持有沙箱，卸载/淘汰不得销毁离屏或侧栏活页面。

组件只经 hooks/服务端口访问外部能力；controller 不导入适配器，domain 只做纯计算。侧栏 tab、composer 上下文仍由既有 UI owner 持有，不与页面状态重复写入。

`preferredDisplayMode: fullscreen` 每次实际工具调用只消费一次；记录归既有侧栏内存，按 workspace/session/plugin/server/resource/toolCall 隔离，随其窗口缓存保留与淘汰。工具行重挂不能重新触发打开并覆盖收起偏好；已显示在侧栏时也消费该调用。手动打开、页面请求以及新工具调用仍走原入口。

- Sampling 使用官方 oncreatesamplingmessage；只有可操作任务声明 sampling:{}。请求携带完整实例凭证，SDK signal 经显式 cancel 到 Agent；controller 将采样计入 busy，切展示位置不取消/重发。结果不进入主聊天；内容扩展和进度仍 pending。

`hostPrimitives.ts` 对 Gen UI 公开 MessagePort 传输、原子移动页面承载层、窗口级容量管理、主题投影和会话动作读取。Gen UI 不复用 MCP 工具调用控制器。绑定显式区分自然流、容器定位与侧栏；Gen UI 预览使用原容器 popover，不重新挂载页面。
