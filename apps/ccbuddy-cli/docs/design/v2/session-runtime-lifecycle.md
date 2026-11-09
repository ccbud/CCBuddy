# Session runtime lifecycle

## 范围与所有者

CCbuddy 的每个 CLI 会话由 SessionLifecycleController 串行协调运行实例，
不创建、删除或重分配持久会话。停止生成、关闭实例、软删除会话是不同命令。
保留现有 Host attachment、workspaceIdentity、owner lease、CommandInbox 和常驻池；
不引入上游 SourceServer、设备体系、共享 CLI 路由或 history-first 产品切换。

- controller 持有实例状态、generation、revision 和每个 session 的操作 flight。
- bootstrap adapter 执行既有 app 初始化和释放，不持有第二份 accepted queue。
- session store 持有历史、删除标记和可信父链；任务索引持有项目组织态。
- gateway / UI 只投影生命周期事实；旧 revision、旧 client 与旧订阅 ACK 不得回写。

## 协议

严格校验 session/lifecycle/getState、ensureReady、stop、restart 的参数和结果；
状态为 unloaded、starting、ready、stopping、faulted。查询不激活实例，缺失或删除
会话报错；ready 只表示实例可用，不表示没有运行任务。

初始化、恢复、fork 和完整 restart 共用同一 controller。restart 在释放前校验
workspaceKey、path、显式 identity 和 remoteSessionId；冲突请求不关闭原实例。
新建允许尚未占用的预分配 ID，不允许覆盖已存会话。普通协议操作拒绝非 ready 实例。

declare workspace → validate persisted ownership → starting → ready
stop / restart → stopping → release → unloaded → optional starting
└ failure → faulted

## 资源释放与失败

先关准入并暂停 active goal，停止/取消前台工作，解除事件订阅，再失效旧 gateway
投影、摘除 runtime registry，清理 MCP UI。等待 App.close 与原 record 持有的
后台 finalization 句柄，最后清理 inbox 和 event store。普通关闭不发布会话删除事实；
删除路径保留独立的软删除和索引清理。自动回收保留原 TTL / LRU / lease 策略。

各资源清理失败仍尝试其他独立阶段，最终聚合失败并进入 faulted 隔离，不用 timeout
把未完成释放伪装成 unloaded。app 物化即登记，即使订阅初始化失败仍可清理；解除
订阅后已经排队的事件不能污染同名新实例。faulted 不自动重试或静默重启整个 workspace。

进程整体退出仍由 ProtocolRuntimeResources 收集全部 app（包含尚未入册和临时 app）
并关闭准入、终止执行与等待 close；不把 per-session controller 当作进程资源清单。
退出中迟到的 app 由该资源 owner 清理，不允许重新登记。

## 目录来源

runtime/capabilities 双向声明 sessionDirectorySource 后，CLI 通过持久化辅助会话
父链解析 directorySessionId，反向请求 Host 项目目录快照。fork 是独立主任务，
不能沿 parentID 改属原项目。显式身份冲突、删除、缺父和环一律拒绝；保留旧 WSL
精确身份解释规则。Host 不在同一恢复请求中反向查询 session/list，避免协议互等。
未协商时不发布严格旧 schema 不认识的字段。

## UI 与交付语义

项目任务提供显式重启操作；远端导航必须先由原 registry 完成 workspace 绑定。
stopping / faulted 失效旧订阅与 owner，不自动激活；ready 后才重连，并拒绝旧
revision、跨 session 事件和旧 subscribe ACK。旧 CLI 不支持时明确报 unsupported。
Desktop 的 continuous 交付和 Web / SSH 的 replayable 恢复继续使用各自现有协议，
单会话重启不改变整进程重启语义。

## 验收

- controller 合约覆盖幂等、single-flight、完整 restart、workspace 冲突与失败隔离。
- 释放 adapter 覆盖 registry 摘除、真实 finalization 等待、独立阶段失败及删除语义。
- 目录来源覆盖历史 worktree child、独立 fork、显式身份冲突、删除、缺父和环。
- UI 回归覆盖停止后不自动启动、ready 单次重连、revision 与旧 ACK 屏障、代理 listener 迁移。
- 项目 Electron 回归覆盖远端绑定前不得创建任务和旧端只读；不等同真实 SSH 或发行包验收。
