# ZCode v3.17.2 分批功能同步

## 同步依据

下游起点是 CCBuddy `3bb0daa`（2.0.12），工作分支为
`sync/zcode-v3.17.2`。上次同步基线由 v3.15.1 审查记录确定为 ZCode
`aac47556`，本次目标为本地 ZCode `a9fe401e`（3.17.2）。

**只依据 ZCode 自身 `aac47556..a9fe401e` 的提交增量识别功能。**
不对两个项目做整树差异同步，不把品牌替换、已移除能力和下游改造当作缺失。
每项功能先理解上游行为和契约，再接入 CCBuddy 现有实现。
本文记录六批已选功能的适配、验证及产品排除项，不代表直接采用上游整套产品实现。

## 下游保留边界

遵守 `byok-only.md`、`history-review.md`、`product-data-isolation.md`、
`product-branding.md`、`mobile-remote-control-removal.md` 的现有规则。
保留历史查看、日历、历史导入、执行安全、两遍压缩和 CCbuddy 自有品牌、
协议、数据目录；不恢复上游账号、订阅、默认凭据、云端分享或手机远控。
不因上游测试退役而删除下游回归，不改下游发行版本号。

## 上游自身更新批次

| 上游提交   | 日期       | 新增/修改功能的审阅入口                                                      |
| ---------- | ---------- | ---------------------------------------------------------------------------- |
| `0a1fc56d` | 2026-10-19 | Gen UI 样式、项目创建/编辑、虚拟项目/归档、工具搜索                          |
| `3c5b2276` | 2026-10-20 | 虚拟项目/归档修订、Skill 和 Bash 行为调整                                    |
| `a60ba6a7` | 2026-10-30 | 项目管理、Gen UI 模型上下文分离、MCP Node 回退、会话生命周期、工具执行与恢复 |
| `a9fe401e` | 2026-11-03 | 项目与会话生命周期修订、自定义命令、插件、Bash/Subagent/Plan 行为调整        |

这些是依据上游变更 spec 确定的审阅入口，不是已完成的移植清单。
项目管理、工具搜索、Gen UI 输入协议、MCP 回退和运行时增强需要各自完整的
调用方、持久化、权限与恢复验收；不能仅复制一个入口或声明完整同步。

## 第二批：项目管理（已接通）

项目组织态由所属 Host 的 tasks-index SQLite 唯一持有；UI 只读项目树并发送保存、
移除、恢复、排序和移动命令，不从当前路径或分组重算归属。项目可包含零到多个 root，
明确主要目录；创建会话固定 cwd，后续项目编辑或移动任务不改变既有 cwd。
软删除项目保留 roots 和任务；重名恢复分配稳定后缀。缺目录或跨 Host 操作明确拒绝。

```text
旧 AppSettings + tasks-index → 启动迁移（checksum + 表级备份 + 单事务）
  → project-storage（组织态唯一所有者）
    → project service → UI hooks/项目侧栏
    ← 现有 task index/syncer（CLI 事实镜像与用户组织态分离）
```

保留 CCbuddy 旧分组与历史入口，Group 不转换为项目；首次项目集合只从已保存工作区
迁移，不能扫描历史会话或 recentProjects 复活已移除入口。NULL project_id 是合法的
最终未归类状态，不反复自动分配。幂等会话预留先于 CLI 首发，fork 继承父任务归属。
迁移基础设施作为独立 sqlite-migrations 端口引入，不改已发布 tasks_schema_migration
的 checksum 与编号；新项目迁移使用独立 schema_migration 账本，只做加法升级。
共享迁移器异步备份声明的 touchedTables，失败回滚，正常降级不消费备份。

不引入上游 Source Server/Connection Profile 新设备产品架构；CCbuddy 原有远程
workspaceIdentity、附件与 owner lease 保持唯一远程路由依据。旧远端缺项目能力时
保留单目录只读投影，不向本机库写远端权威项目。所有新建目录均由所属 Host 校验。
自动归档由 Host 调度器触发，排除置顶和真实运行任务；读取/点击不得触发归档。
彻底删除数据必须与软删除分离，保护其他项目仍引用的目录及活跃会话，失败可重试。

验收需要真实旧库迁移/备份恢复、重复启动、并发预留、跨 Host 拒绝、归属/目录不变、
软删除/恢复、自动归档和项目侧栏交互 E2E；只完成存储模块不能将本批标记完成。

TaskIndexRepo 在旧库准备完成后读取注入的设置快照，再执行项目迁移；Worker 的
prepared 快速路径不能跳过项目升级。CLI 快照和事件沿原索引写入路径，同事务写入
项目所需事实和首次身份；用户置顶、归档、项目归属不从 CLI 事实重建。
标题、已读等组织操作不得伪造 CLI 活动时间，项目查询不承担补写职责。

### 第二批阶段记录（2026-11-09）

已接通独立迁移账本、备份恢复、项目仓储、TaskIndexRepo、Host 服务注册和 RPC
代理。快照摄入在同一 SQLite 写锁内合并 CLI 事实与既有组织态，保留旧 Group API。
自动归档从 grouped 列表读取移到 Host 扫描器；读取不再触发归档，活跃任务来自
原 syncer 的 live summaries，不为扫描启动 Agent。保留下游七天默认策略与关闭默认值。

当前回归覆盖 prepared 旧库升级、设置快照读取、幂等创建、cwd 固定、跨 Host 拒绝、
软删除/恢复、置顶/归档/用户标题保留、重启归属、目录失效、远程服务路由和扫描串行。
以上为第二批早期阶段记录。项目侧栏/编辑器、创建/恢复目录传递、远端能力装配和
本机数据删除现已接通，最终状态与真实验证结果见文末，不能沿用本段推断尚未实现。

## 第一批：Gen UI 样式与预览增强

### 所有权与数据流

```text
App styles.css（主题和字号唯一来源）
  → Gen UI theme adapter（展示投影）
  → 现有 AppBridge HostContext
      ├─ styles.variables：SDK 校验的标准 MCP token
      └─ ccbuddy/genUiStyles：仅 --gen-ui-* 字符串变量
  → 现有 Gen UI guest（校验后更新根 CSS 变量）
  → visualize.css（内联和独立 HTML 导出共用）
```

不增加缓存、定时器或业务状态。主题/字号变化复用根节点 MutationObserver。
不修改 workspace identity、desktop-continuous、Web/SSH replayable、widget
state 或模型输入语义。第三方 MCP App 的标准主题投影保持不变。

### 产品规则

1. 正文和控件跟随宿主字号；标题按正文 +4/+2/+0，辅助文字 -2。
2. 圆角使用 sm/md/lg/xl 独立 token；卡片嵌套与控件按层级收敛，旧类名仍可用。
3. 控件 primary 与内容 accent 分离，链接和图表保留强调色。
4. 同步按钮变体、输入框、textarea、checkbox 半选、switch、disabled 与
   focus-visible 样式。保留触摸 44px 目标和输入防缩放规则。
5. 专用变量独立于 SDK 严格枚举；shared schema 拒绝非专用 key 和非字符串值。
6. 展开预览标题可见并截断；缺省标题只用于无障碍。加载状态显示 loading 图标。
7. top-layer 预览复用现有承载层，由锚点传递底部圆角；打开 tweak 面板时
   取消底部圆角，关闭后恢复，不重建 guest。
8. 独立 HTML 导出共用同一 CSS，包含 light/dark 默认值，资源 hash 必须一致。

### 验收

- shared schema、主题投影和 guest HostContext 的定向回归。
- 14/18px、缺省值、标准 SDK 校验、专用 token 和第三方映射不变。
- Electron E2E：加载态、展开标题、圆角、控件状态、主题/字号变化与实例保留。
- 独立导出、资源 hash、架构、根 typecheck/lint 与受影响 CLI 验证。
- 未实际执行的平台或视觉场景明确标记，不沿用上游的通过声明。

## 第一批完成记录（2026-11-09）

已移植 Gen UI 标准/专用主题分离、完整字号与圆角投影、控件变体与状态、
展开预览标题/圆角/加载图标以及内联/独立导出的统一样式。保留 CCbuddy
协议命名和原有中英文加载文案，不移植上游新增的产品域名 CSP 白名单。
CSS 保留下游焦点及圆角适配，运行时清单记录下游实际 CSS 的 SHA-256；
其他下游资源 hash 不变，不拿上游 hash 替代本地资源完整性校验。

使用 Node 24.14.0 和 pnpm 10.33.2 实际执行：

- `pnpm build:bootstrap`：通过（包含 Desktop Renderer 和 Web 构建）。
- Gen UI 定向 Vitest：6 个文件、53 个测试通过，包含原有状态/边界回归。
- `python3 packages/desktop/scripts/gen-ui-vendor-export.test.py`：3 个测试通过。
- `node packages/desktop/scripts/gen-ui-e2e.mjs`：通过。覆盖真实 Electron
  深浅主题、14/18px、390/1100px、按钮文字边界、focus-visible、checkbox
  半选、输入状态、展开标题/圆角、加载态、原 guest 保留及独立导出触摸模拟。
- `pnpm typecheck`：通过。
- `pnpm lint`：通过，54 warnings、0 errors。
- `pnpm architecture:check --changed`：通过，0 violations。
- `pnpm --dir apps/ccbuddy-cli typecheck`：通过，27 个 Turbo tasks 成功。
- `pnpm --dir apps/ccbuddy-cli lint`：未通过。adapters 的 storage、skills、
  MCP、plugins 等既有源文件超过 400 行限制；这些文件与下游分支起点相同，
  本批未修改。未为通过门禁修改无关代码或放宽规则。
- 受影响 TS/Markdown 文件格式检查、资源完整性和 `git diff --check`：通过。

CLI 命令执行时将根 `node_modules/.bin` 加入 PATH；首次只在嵌套 workspace
执行时未找到 `turbo`，补齐执行环境后得到上述真实结果。Electron fixture
使用临时数据目录；开发 fixture 的 CSP 提示不代表本轮修改了正式产品 CSP。
截图已检查；未执行 Windows/Linux 原生视觉验收、真机触摸或最终发行安装包验收。

**历史阶段说明**：第一批完成时，其余五批尚未移植；本轮已继续接通，最终清单见文末。
各项仍只依据上游自身增量，不能把第一批的验证范围外推到其他功能。

## 后续批次与提交规则

用户确认总计划按六批功能域推进；所有批次完成前不创建中间 commit。
最终统一验证、一次性提交并创建 PR，不把未完成的批次发布为已同步。

项目管理增量实际包含项目/任务存储迁移和多目录归属，不能只复制新的 UI。
实施顺序可以先完成独立的协议与 CLI 能力，再接入项目管理；功能编号保持不变。

### 第四批：Gen UI 模型上下文分离（已接通）

```text
Host widget state（最新状态唯一所有者）
  → UI 固定 workspace/session/command 身份后采集一次 modelContent
  → sendText { text, genUiContext }（同一输入，不同字段）
  → CommandInbox → canonical intent（该次快照的持久化唯一所有者）
      ├─ transcript/queue/history：只投影 text 与正常附件
      └─ turn/steer/replay：复用 systemReminderAttachmentEntry 提供不可信模型上下文
```

快照仅含 `{ path, state }`；privateContent 不传给执行端。限制沿用每项 16 KiB、
最多 100 项、总计 64 KiB 和确定顺序。空数组保留为新协议标记。
排队、引导、立即发送、编辑与重试沿用原输入快照，不在执行/恢复时重读 Host。
页面状态变更不发起轮次；取消输入不留下孤立 reminder。
冷恢复与分叉沿用 canonical intent，不建立第二份状态存储。
旧格式仅解析合法的尾部状态块，作为兼容输入恢复为独立字段，用户可见正文去掉
合法尾块；无效或位于正文中间的相似文本保持不变。
执行端不访问 Desktop state 文件，desktop-continuous/Web/SSH-replayable 链路不变。
不恢复上游分享/移动远控入口。

验收覆盖 schema 边界、privateContent 隔离、普通执行/排队/引导、快照固定、
取消、持久化、历史可见正文、兼容尾块、编辑重试和冷恢复。每一传播层的字段
都必须接通后再将本批标记完成，不能仅修改 UI。

### 第五批：MCP Node/npm/npx 回退（已接通）

Electron Node 中的 stdio MCP 连接由 bootstrap 注入惰性 fallback provider；
adapter 在 server env 合并后将 shim 目录追加到 PATH 末尾，用户 Node 始终优先。
纯 Node CLI、SEA、SSH 和非 stdio 连接不改变行为。shim 使用 CCbuddy 专用环境变量、
稳定版本目录与原子写入；多进程并发初始化不覆盖执行中的文件，保留退出码和参数。
初始化受现有连接超时与取消控制；失败保留原始连接错误，不伪装为连接成功。

打包脚本通过固定版本和 SHA-512 校验缓存 npm tarball，放在 agent bundle 旁的
`node-runtime/npm`，不把 npm 加入 workspace dependencies，避免覆盖开发机 npm。
本项目 Electron 41 不跟随上游升级到 Electron 44，因此采用兼容现有运行时的
npm 11.11.0，而不是上游要求更高 Node 小版本的 npm 12。完整性取自 npm registry
该固定版本元数据。验收包含无 Node PATH 的真实子进程、优先级、Windows shim、
取消/超时、并发初始化、缓存损坏与资源 staging；Windows 原生执行需单独注明。

### 第三批：工具发现与按需加载（已接通）

目录来源为现有 tool registry 与已授权 MCP descriptors。唯一执行身份为 ToolSearch；
local 模式仅在模型请求中投影为 LocalToolSearch，DeferredToolCall 在执行器中解包为
真实工具身份，沿用原权限、trace、调度与结果持久化，不另建执行通道。
搜索按名称、别名与关键词匹配，用户关键词不解释为正则；不执行未授权目录中的工具。

```text
registry + canonical discovery/history → request-local exposure → model request
  ↑                                         ↓
existing executor ← ToolSearch / DeferredToolCall → canonical tool result
  └── persistence / compact metadata / hydration（不新增共享发现状态）
```

配置支持 off/local/native/auto；不恢复上游账号、订阅或默认凭据。
App 设置只展示 auto/local/off，默认为 off；BYOK 的 auto 使用 local，原生协议只允许
CLI 显式选择 native。设置写入共享 AppSettings，由 Host 在物化新会话/冷恢复时读取，
活跃会话保持启动快照，子会话继承父配置。UI 不持有第二份执行配置。
native 仅在 Anthropic Messages 兼容协议允许；BYOK 不自动获得上游订阅专属默认行为。
alwaysLoad 工具保持常驻；延迟工具按本轮授权和目录投影。重试复用请求准备结果，
恢复与两阶段压缩保留发现元数据，不能因投影改写 canonical history。
验收覆盖搜索边界、别名/恶意关键词、local/native/off、真实执行身份、权限拒绝、
请求记录、MCP descriptors、配置往返、恢复和压缩后的发现状态。

### 第六批：运行时与工具配套增量（已接通）

会话删除与项目归档分离：保留下游原归档接口，新软删除时间独立落库，普通 CLI 列表
不再返回删除行；去激活仅释放 runtime，不能删除历史或伪造 session.removed。
彻底删除只接收经 Host 确认的本机会话 ID/目录，运行中或仍被其他会话引用附件的树保留。
附属后代随父会话清理，独立 fork 不级联。文件清理失败保留数据库行以便重试；
先删除会话文件，再事务删除正文/索引行，最后清理 sessions-index 投影。
仅删除 CLI 数据根与 Host checkpoint/memory 的派生目录，不删除项目工作文件。

```text
确认已移除项目 → Host ProjectDataPort → CLI residency/reference preflight
  → release idle runtime → remove owned files → SQLite purge → forget indexed session
```

新增 CLI 迁移追加编号，不修改下游既有 migration checksum 或档案语义。

Read 状态以规范化路径为唯一键，写入顺序由同步分配的 snapshotIndex 固化。
Read 返回 file_unchanged 不产生新快照；Write/Edit/工作流只在成功且有完整
freshness 元数据时持久化。冷恢复不读取当前磁盘补齐历史；同一 assistant 的
全部快照有序号时按序号恢复，否则兼容旧 part 顺序。保留原始请求路径供 deny 判定。
压缩保留 CCbuddy 两阶段摘要；文件补回必须重新读取当前磁盘，原始与规范化路径
任一被拒即跳过。MEMORY、指令和计划文件由原通道负责，不重复补回。
持久化 compact 成功后才替换 live Read 表，失败保留旧表；恢复范围视图不伪装成完整读取。

ToolSearch 的配套执行改造沿用 executor admission：模型包装先解包，再按真实工具
校验参数、权限和并发属性；模型历史恢复包装，内部 trace/持久化保持真实名称。
Hook 附加上下文按原工具批次排序、沿同一提醒通道持久化，不能覆盖工具的授权结果。
工具错误必须保留配对结果，目录不存在、未知名称与缺少 schema 提供可纠正提示。
MCS 和非 MCS 请求均保持真实用户输入与页面状态的因果顺序；工具结果后的提醒只在
会合并相邻 user 内容的 provider 上折叠。请求重试不得追加第二份 canonical 提醒。
两阶段压缩的预摘要、旧上下文选择和失败回退继续由 CCbuddy 的现有实现负责，
只在摘要请求和 compact metadata 上接入工具发现，不能整段替换掉下游压缩实现。
其余文件编码、会话生命周期与存储事务在各自实际移植前补充具体规则和回归场景。

文件编码采样只补齐 UTF-8 尾部候选所缺的字节，补齐后严格校验；GBK/GB18030 不能
因为采样末尾的高位字节被误判为 UTF-8。循环读取必须遵守取消信号，不改变文件原编码。
Bash 失败结果使用有界头尾文本保留实际错误尾部，多字节文本不因通用字节预算再次
退化为仅头部 artifact 预览；成功的大输出仍按原规则落盘。保留闲时任务禁止后台的
下游策略，不引入上游闲时账号或后台生命周期改造。超时自动后台单独标记实际超时，
会话环境变量仅投影现有 session/workspace 身份，不更改用户 PATH。

### 项目执行目录的贯通规则

项目侧栏通过 hooks 调用所属 Host 服务，展示项目/任务树、置顶和归档筛选、
项目编辑（名称、多个 roots、主要目录）、移除与恢复、任务移动及归档/取消归档。
移除是软删除，不等同销毁数据；彻底删除需测量与确认并通过同一 Host 数据端口。
旧历史、日历、Group 和远程工作区入口保留，不以项目区替换这些下游能力。
项目新草稿携带显式 projectId；它是 renderer 草稿意图而非项目持久化事实，
写入 createSession 信封以支持原命令重试，Host 校验后进行权威归属预留。
项目草稿不得复用其他项目（即使 cwd 相同）的预热会话。

项目与任务归属由所属 Host 的 ProjectRepository 唯一持有；界面只传项目 ID，
prepareSession 固化 cwd，创建命令在 CLI admission 前原子预留任务 ID 和目录快照。
同一 V4 clientId/commandId 重试复用原任务，不重复创建。项目 roots 变更不改变既有 cwd；
恢复与冷订阅读取所属项目当前附加目录，缺项目、跨 Host 或持久化父链异常必须拒绝。
附加目录通过严格 create/resume、runtime preferences、V4 cold resume 到 runtime 和模型环境；
旧协议不认识该字段时不得静默省略。目录提示不放宽现有 Read/Bash 权限。

```text
UI → ProjectService.prepareSession → Host reserveCreatedTask → CLI create admission
历史订阅 → Host resolveSessionDirectories → V4 cold resume → runtime → env_info
```

desktop-continuous 与 Web/SSH replayable 继续复用原 attachment、workspaceIdentity 和 owner lease，
不新建连接或设备身份；子会话继承可信父链的目录，不从用户正文推断项目。
验收覆盖目录提示、显式空列表、创建幂等、冷恢复、父链、项目变更后的 cwd 固定及安全拒绝。

### 远端项目能力与导航

目录来源通过 runtime/capabilities 双向声明 sessionDirectorySource 后启用。
CLI 仅沿持久化辅助会话父链解析 directorySessionId；主任务不因 fork 的 parentID
改属原项目。无显式身份的历史 child 可具有不同执行 cwd，但显式身份冲突、缺父、
删除和环必须拒绝。反向偏好请求直接携带可信目录 owner，Host 不在同一恢复请求中
反向调用 session/list，避免串行协议互等；旧端仍使用既有只读查询路径。

```text
Host capability declaration → CLI persisted parent chain → directorySessionId
  → Host project directory resolver → startup snapshot → child inheritance
```

远端项目服务经现有物理连接代理，SystemInfo/HTTP capabilities 显式声明 virtualProjects；
缺省使用旧单目录只读投影，不能因 RPC proxy 对象存在就判定支持。新端远程项目只允许
一个 root，禁止远端彻底删除，Host 数据库拥有自己的 local 组织态，不写 Desktop 影子库。
列表标识按现有 RemoteTarget 生成；它不代表已绑定 attachment，不能据此调用 Agent。
仅订阅已在原远端 store 登记的目录。选择其他目录先走 onSelectRemoteProject 完成原
registry 状态机绑定，再按确认的 identity/session 导航或创建；不得暗中复用旧逻辑会话。

```text
read capability → remote project facade → read-only tree
user selection → existing remote project action → registry.bindWorkspaceContext
              → store identity/session binding → task navigation / create command
```

### 运行实例生命周期

每个 CLI session 由单一 lifecycle controller 串行协调初始化、停止与重启；
持久会话事实和原 CommandInbox/owner lease 不变。停止运行实例不同于停止生成或软删除。
同步关闭准入与摘除 registry 后，依次收口投影、MCP UI、app.close 和 detached runner；
全部真实释放后才允许重新激活。释放失败进入 faulted 隔离，不用 timeout 假装完成。
冷订阅与旧 resume 共用生命周期 owner，重启前校验原 workspaceIdentity，
相同 cwd 不代表同一远端会话。新建只允许未使用的预分配 ID，不能覆盖既有会话。

```text
create/resume/cold subscribe → lifecycle owner → starting → ready
stop/restart → close admission → detach registry → await resources → unloaded → starting
                                                       └ failure → faulted
```

### 插件与附加目录发现

附加目录仅补充显式 `.agents/skills` 与 `.agents/commands` 兼容目录，
CCbuddy 自有状态仍保存在应用数据根，不恢复上游项目内产品目录。附加 skill/命令
以目录 basename 限定名发现；同名路径去重，cwd 不重复扫描。禁用技能发现时不绕过开关。
插件 describe 的已缓存只读分支不等待下载写锁，缺 manifest 的懒写仍经同一存储锁串行。
publisherType 只是商店显示元数据，不影响授权；agent 路径只用于 CLI 加载，不暴露详情协议。
不恢复产品绑定的云部署、订阅鉴权或上游市场默认凭据。

### 自定义命令 shell 交接

自定义命令解析只改写文本，不在展开阶段执行 shell。行内与 fenced `!` 块交给模型
通过原 Bash 工具执行，保留可见调用和权限审批。先识别正文块再替换用户参数，
不将参数中的 `!` 当作可执行块；插件变量只替换已知纯变量，不支持的变量或修饰符
整块跳过并给出说明。Windows 插件路径改正斜杠，保留 CCbuddy 环境变量命名。
附加目录命令按目录 basename 命名空间发现，不改变项目身份与权限。

### 项目删除交互与所属 Host

项目行仅保留新任务与菜单入口；菜单提供编辑、置顶、排序和移除。
已移除项目的彻底删除先测量会话、记忆和检查点字节，再危险确认；取消无副作用。
完成后展示实际释放字节、保留的运行/引用会话及失败数，未全部完成的项目可重试或恢复。
工作目录文件永不删除。远端附着 Host 不装配本地数据销毁端口，其数据库仍以本机为事实所有者，
不将 Desktop 的远端 workspaceIdentity 误当作另一个 Host 的数据库所有权。

## 最终适配清单（2026-11-09）

| 批次 | 已接通范围                                                                                                             |
| ---- | ---------------------------------------------------------------------------------------------------------------------- |
| 1    | Gen UI 独立主题 token、字号/圆角、控件状态、预览标题/加载态、独立导出                                                  |
| 2    | Host 项目 SQLite 迁移、项目树/编辑/多目录、任务归属、自动归档、本机数据清理、远端单目录能力降级                        |
| 3    | ToolSearch 配置、local/native/off 投影、deferred 工具真实身份执行、权限/MCP/恢复/压缩配套                              |
| 4    | Gen UI 输入快照独立字段、canonical intent/队列/重试/恢复，用户正文与模型上下文分离                                     |
| 5    | Electron/Node 24 bundle 内 npm/npx 安全回退，保留用户 PATH 和外部可执行程序优先级                                      |
| 6    | Read 快照顺序/冷恢复/compact 补回、两阶段压缩兼容、文件编码/Bash 尾部、自定义命令 shell 交接、插件/Skill、会话生命周期 |

项目存储及 CLI 均采用追加迁移，未引入上游 frozen baseline 或替换下游迁移账本。
CLI 生命周期与父链只接入现有 Host，不移植 SourceServer 新设备/共享路由体系。
standalone-server 与远端附着 Host 均保持单 root、禁本机彻底删除的服务边界。
未移植账号、订阅、默认凭据、云分享、手机远控及依赖这些产品入口的行为。
版本号保持 2.0.12；历史、日历、导入、安全拒绝、两阶段压缩和原远端 owner lease 保留。

## 最终验证记录（Node 24.14.0）

- 根 `pnpm typecheck` 通过；CLI typecheck 为 27/27 tasks 通过。
- 根 lint：54 warnings / 0 errors；架构检查：0 violations。
- 根定向 Vitest：19 files / 86 passed，包含项目迁移/服务/远端边界、生命周期 UI、
  Gen UI、工具设置和运行时资源 hash。原文件监听用例在两次混合运行中超时，
  单独复跑及最终混合运行通过；没有删测试、加 timeout 或改动该既有实现。
- CLI core：22 files / 195 passed；adapters：9 files / 71 passed、1 skipped；
  bootstrap（含 lifecycle/session-data 源内合约）：12 files / 58 passed。
- 新 managed contracts 与 shared session-data 定向运行：4 files / 6 passed。
- node:test：远端云能力不可恢复边界、npm 缓存/完整性测试 2 passed。
- Python 独立导出/vendor 回归：3 passed。
- 真实 Electron Gen UI / Projects / ToolSearch E2E 通过，包含本机多 root 创建、移除/恢复、
  测量/取消/确认彻底删除、远端绑定前不得创建任务、旧端只读降级与设置持久投影。
  Fixture 的项目组织态使用真实 SQLite；远端绑定受控模拟，不冒充真实 SSH 环境。
- Read 补回权限回归使用真实磁盘/文件系统 adapter 与原 executor deny-probe；
  两阶段 compact 集成覆盖成功单次提交、持久化失败不替换历史/Read 表、首遍失败回退和取消迟到结果。
  摘要模型请求为受控测试端口，不调用外部模型。
- `pnpm build:bootstrap` 通过（含 Desktop 与 Web），资源完整性和 diff whitespace 检查通过。

### 既有门禁限制

- CLI 整体 lint 不通过，首先报 contracts 的 6 个既有 max-lines 错误。分别执行
  core/adapters/bootstrap lint 仍有既有超长文件错误。对受改动文件以 HEAD 原文和
  同一 lint 配置核实：本轮新增的三个越线已按职责拆分，不新增 max-lines 违规，
  不重构无关长文件、不修改 lint 或架构 baseline。
- CLI 整体 test 已实际尝试，contracts 配置的 `vitest tests` 因目录内无测试文件
  退出 1，Turbo 提前停止；另有既有 workspace lockfile 提示。因此单独执行全部受影响
  core/adapters/bootstrap 测试，不能把整体 CLI test 写成通过。
- 未执行 Windows/Linux 原生安装包、真机触摸、真实 SSH 连接、发行包升级或外部模型验收。

按用户要求，所有六批修改合为一次最终提交并提 PR，不创建中间 commit。

### PR #59 打包回归修复

- CI 的类型、lint、格式和架构任务通过，macOS 打包在构建 CLI bundle 时失败。
  GenUI 模型上下文新增的 `@ccbuddy/shared/gen-ui` 子入口缺少精确 alias，
  被 esbuild 的通用 shared alias 错误改写为 `src/index.ts/gen-ui`。
- 在现有 CLI 构建别名表补齐 GenUI 入口，不改运行时协议、产品行为或门禁规则。
- 新增实际 esbuild 子入口打包测试并接入 PR 检查；修复前已复现同一解析错误。
  完整 runtime-assets 准备与 macOS 安装包构建作为本次修复的验收路径。
- 本地 Node 24.14.0：根 typecheck/lint/fmt/架构检查通过，打包相关测试 29/29，
  Desktop 历史平台集成测试通过；生产配置的 runtime-assets 准备及 Desktop/Web 构建通过。

### 2.0.17 安装包启动回归

- SQLite 迁移基础设施的 backup/restore 使用 Node 内置 `node:sqlite`，不依赖 npm
  `sqlite` 包。tsup 默认剥离 `node:` 前缀，使发布产物出现 `from "sqlite"`，
  在 Main 模块链接阶段就崩溃；不是用户安装操作或数据库迁移执行失败。
- Main、Host、Scheduler 的 Node ESM 构建必须保留内置模块协议。修正在构建边界完成，
  不改迁移语义，不通过安装同名 npm 包、复制 node_modules 或修改用户安装目录规避。
  不改变 sandbox preload 的 CommonJS 兼容策略。
- 使用实际 tsup 目标配置打包并加载 SQLite 迁移公共入口，覆盖三个 Node ESM 目标；
  生产构建完成后扫描实际产物的模块引用，拒绝丢失协议的 prefix-only Node 内置模块。
  检查进入 PR CI，补齐只打包 ZIP/DMG 而未验证该启动链接错误的门禁缺口。
