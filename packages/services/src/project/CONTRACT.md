# Host 项目服务

规格与集成进度：`docs/specs/upstream-v3.17.2-integration.md` 第二批。

组织态的唯一写者是当前 Host 的 project-storage。服务通过注入的仓储端口访问
同一 tasks-index 数据库，不读取 CLI 数据文件、不启动 Agent。UI 必须经 hooks 调用。

- 本地项目允许零到多个 roots；保存前在所属 Host 校验绝对路径及目录存在性。
- prepareSession 固定主要 cwd 与附加目录；已有主要目录失效时拒绝，不静默重建。
  空项目的默认目录由 Host 创建并原子登记；多窗口重复准备复用同一项目目录。
- readProjects/readTree 纯读取；主要目录状态异步派生，不落库或持久缓存。
  并发 stat 复用进行中的请求，超时返回 unavailable，下一轮读取重新探测。
- 移动任务不改变 cwd 或 CLI 事实。跨 Host 操作拒绝；新增 root 必须显式确认。
- 软删除保留 roots 和任务；恢复不要求目录仍存在，重名分配后缀。
- Host 自动归档扫描器启动时、每五分钟及相关设置变化时运行；不挂在列表读取上。
  活跃任务由既有 syncer 的 live summaries 提供，置顶与活跃任务不归档。
- ProjectDataPort 是彻底删除的唯一副作用端口；保护其他项目引用的目录、运行中
  或被引用的会话。未装配该端口时明确返回 project.data-unavailable，不执行删除。

远程继续使用既有 attachment/workspaceIdentity/owner lease。
远程身份绑定和旧单目录只读适配器只提供契约，必须由装配层确认能力后使用，
不能从本机路径推断远端组织态或新建另一套 Source Server。

当前已注册本地 Host 服务与 RPC 代理；项目侧栏、会话创建/恢复的目录接线、
远程能力装配和数据删除端口尚在集成中，不能据此宣称项目管理端到端完成。
