# v3.15.1 同步审查与修复

## 范围

审查 `sync/upstream-v3.15.1` 的同步提交 `27c5bd6a`，以 `origin/main`
`861c05bf` 为 CCbuddy 基线，参照 `/Users/WangYanmin/github/zcode/ZCode`
的 `aac47556`（v3.15.1）。结合差异、当前源码、回归测试及隔离 Electron
运行证据检查；本次修复保留 BYOK、CCbuddy 品牌、数据隔离和外部历史能力。

产品规则、接口、状态所有者与事件顺序见
[集成 spec](../specs/upstream-v3.15.1-integration.md)。

后续按用户要求彻底移除移动端远程控制，移除范围和验收见
[移除 spec](../specs/mobile-remote-control-removal.md)。普通 Web、SSH 和 Bot 的
共享远程会话仍使用既有 registry、Host 和 RPC。

## 已修复的问题

| 优先级 | 确认的问题                                                                        | 修复与验证                                                                                                               |
| ------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| P1     | 构建引用缺失脚本、包、配置和公开导出；锁文件与 workspace 不一致                   | 清理已移除模块的构建入口，补齐当前公开接口，重生成锁文件；冻结安装、CLI、Desktop 和 Web 构建通过                         |
| P1     | Main 的远程工作区目标同步与 attachment 生命周期装配不完整                         | 同步复用既有 remote-session registry；删除手机 manager，保留 window-scoped Host；实际 Main assembly 回归通过             |
| P1     | 网站权限桥未装配，权限和设备选择可能由错误窗口或 frame 处理                       | 在 guest 创建前装配，绑定真实 owner 主 frame，按 guest/frame/origin 隔离设备选择；权限回归通过                           |
| P1     | 历史入口缺失，升级后的历史会话仍被 legacy 订阅标记阻断                            | 恢复侧栏、主视图和原生菜单，成功升级后释放 legacy 标记；桌面 continuous、普通 Web/SSH replayable 回归及历史交互 E2E 通过 |
| P1     | 保存、查找、运行 workflow 的部分路径遗漏 workspace identity                       | 全链传递 identity，保留本地路径 fallback；同路径不同身份隔离回归通过                                                     |
| P1     | Plugin UI timeline 和卡片使用不同 scope key；子代理模板接口与 Host 快照更新不一致 | 共用现有 scoped key 和 retention；异步读取模板后纯解析每份模型快照；相关回归通过                                         |
| P1     | Main 在测试环境读取不存在的 provider 模板；同步重新引入账号与购买入口             | 开发和正式包使用实际 BYOK 模板，清理对应入口；隔离真实桌面启动进入引导页，无模型配置错误                                 |
| P1     | 浏览器异步摘要、恢复和关闭期间可能继续操作已关闭或已转移的 tab                    | 在 await 后复核对象、生命周期与 scope；使用对象局部 close promise 保证关闭与转移顺序；32 项交错回归通过                  |
| P1     | 恢复仓库写盘失败前已修改内存快照，失败后缓存与磁盘不一致                          | 修改副本，原子写成功后提交缓存；真实 EISDIR 写失败及恢复后的重试通过                                                     |
| P2     | macOS 启动时用满画布 PNG 替换 Dock 图标，视觉尺寸变大                             | 安装版保留 bundle 图标，开发版使用留白资源；原生 Electron 验证安装版替换 0 次、开发版替换 1 次                           |
| P2     | React 前的 Desktop/Web 启动壳仍显示旧标记；强制升级窗口按 cwd 读图并回退为旧字母  | 启动壳引用 CCbuddy 图片，升级窗口异步读取随包图标；真实构建首帧与资源/缺图回归通过                                       |
| P2     | 同步新增的更新状态返回类型无法正确收窄                                            | 用实际状态 kind 约束类型；同步新增的 Main 类型诊断已消除                                                                 |

## CR 阶段验证

使用 `mise.toml` 指定的 Node 24.14.0：

- `pnpm typecheck`：通过。
- `pnpm lint`：通过，0 errors，59 项既有 warnings。
- `pnpm architecture:check --changed`：通过，0 violations。
- Desktop/shared 合并回归：61/61；durable close 回归：9/9。
- CLI/service 定向回归：12/12；构建配置、启动品牌和模板回归：10/10。
- UI 定向回归、历史导航 Electron E2E、原生 Dock 检查及隔离桌面启动：通过。
- CLI 全量类型检查与构建/staging、Desktop Main/Host/preload 等 tsup、Desktop Renderer 和 Web Vite：通过。
- `git diff --check`：通过。

## 仍未通过的附加检查

- 独立 Desktop Main `noEmit` 仍失败。隔离 `origin/main` 并重建依赖后复现了
  这些既有诊断，涉及 rootDir/DOM、存储与原生类型、更新测试和实时事件类型；
  同步新增诊断已修复。标准仓库类型检查的范围不含 Main。
- CLI 全量 lint 仍有 `packages/debug/src/App.tsx` 的既有 max-lines 错误；
  该文件与 `origin/main` 相同，本次未修改。

未生成或安装最终分发包。CR 运行验证使用隔离数据目录；未执行
Windows/Linux 原生环境的端到端验证。后续移除阶段的验证结果见移除 spec。
