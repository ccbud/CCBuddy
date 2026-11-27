// 官方插件的暂存清单单独成模块：scripts/test/upstream-build-inputs.test.mjs 直接导入它，
// 校验每个插件的源码 manifest 与必需 seed 文件都在仓库里。
// ccbuddy.cjs / .node-bundle-meta.json 的落点由 stage-agent-bundle.mjs 自己解析（同源）。
// node_repl 宿主抽成独立包
// @ccbuddy/node-repl-host 之后，browser-use 不再产出 dist/mcp/server.js，CUA 资产
// （docs/computer-use.md、scripts/computer-use-client.mjs）也已归 @ccbuddy/ccbuddy-cua-plugin。
// 这份清单当时漏改，打包准备阶段照旧去 browser-use 要那三个文件，直接 missing runtime 挂掉。
// dev 链路走的是 scripts/build-desktop-agent-cli.mjs 的 requiredDevPluginRuntimeBuilds（那份改对了），
// 两份平行清单各自维护，所以 dev 测不出来 —— 权威归属见 bootstrap/official-plugin-definitions.ts。
const browserUseRequiredRuntimePaths = [
  "scripts/browser-client.mjs",
  "docs/api.json",
  "docs/documents.json",
  "docs/overview.md",
  // documents.json 已暴露 recording lookup，桌面安装包不能复用缺少正文的 runtime。
  "docs/recording.md",
  "docs/workflow.md",
  "skills/control-browser/SKILL.md",
  "skills/web-gui-tester/SKILL.md",
];
// 文档插件（documents / pdf / presentations / spreadsheets）的查看面板由共享包
// @ccbuddy/office-runtime 构建进各插件 dist/；插件包自身没有 TypeScript 源码。
const officeInvocationPaths = [
  "scripts/ccbuddy_libreoffice.py",
  "scripts/libreoffice-profile/user/registrymodifications.xcu",
  "scripts/libreoffice-profile/user/basic/script.xlc",
  "scripts/libreoffice-profile/user/basic/dialog.xlc",
  "scripts/libreoffice-profile/user/basic/Standard/script.xlb",
  "scripts/libreoffice-profile/user/basic/Standard/dialog.xlb",
  "scripts/libreoffice-profile/user/basic/Standard/CCbuddy.xba",
];

const officeViewerRuntimePaths = ["dist/server.mjs", "dist/ui/assets.json", "dist/ui/panel.html"];
export const officialPluginPackages = [
  {
    packageName: "@ccbuddy/android-emulator-plugin",
    relativePath: "apps/ccbuddy-cli/packages/android-emulator-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: ["dist/mcp/server.js"],
    runtimeBuildScript: "scripts/build-mcp.mjs",
    stagedPath: "packages/android-emulator-plugin",
  },
  {
    packageName: "@ccbuddy/documents-plugin",
    relativePath: "apps/ccbuddy-cli/packages/documents-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: officeViewerRuntimePaths,
    requiredSeedPaths: [
      "skills/docx/SKILL.md",
      "skills/docx-viewer/SKILL.md",
      ...officeInvocationPaths,
    ],
    runtimeBuildScript: "../office-runtime/scripts/build.mjs",
    stagedPath: "packages/documents-plugin",
  },
  {
    packageName: "@ccbuddy/pdf-plugin",
    relativePath: "apps/ccbuddy-cli/packages/pdf-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: officeViewerRuntimePaths,
    requiredSeedPaths: [
      "skills/pdf/SKILL.md",
      "skills/pdf-viewer/SKILL.md",
      ...officeInvocationPaths,
    ],
    runtimeBuildScript: "../office-runtime/scripts/build.mjs",
    stagedPath: "packages/pdf-plugin",
  },
  {
    packageName: "@ccbuddy/presentations-plugin",
    relativePath: "apps/ccbuddy-cli/packages/presentations-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: officeViewerRuntimePaths,
    requiredSeedPaths: [
      "skills/pptx/SKILL.md",
      "skills/pptx-viewer/SKILL.md",
      ...officeInvocationPaths,
    ],
    runtimeBuildScript: "../office-runtime/scripts/build.mjs",
    stagedPath: "packages/presentations-plugin",
  },
  {
    packageName: "@ccbuddy/spreadsheets-plugin",
    relativePath: "apps/ccbuddy-cli/packages/spreadsheets-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: officeViewerRuntimePaths,
    requiredSeedPaths: [
      "skills/xlsx/SKILL.md",
      "skills/xlsx-viewer/SKILL.md",
      ...officeInvocationPaths,
    ],
    runtimeBuildScript: "../office-runtime/scripts/build.mjs",
    stagedPath: "packages/spreadsheets-plugin",
  },
  {
    packageName: "@ccbuddy/visualize-plugin",
    relativePath: "apps/ccbuddy-cli/packages/visualize-plugin",
    requiresRuntime: false,
    requiredSeedPaths: [
      "skills/visualize/SKILL.md",
      "skills/visualize/references/api.md",
      "skills/visualize/references/styles.md",
      "skills/visualize/tweak.md",
      "skills/visualize/LICENSE.md",
      "skills/visualize/scripts/render.py",
      "skills/visualize/assets/visualize.css",
      "skills/visualize/assets/visualize.html",
      "skills/visualize/assets/calendar.js",
      "skills/visualize/assets/runtime-manifest.json",
      "skills/visualize/scripts/vendor.py",
      "skills/visualize/assets/vendor/manifest.json",
      "skills/visualize/assets/vendor/floating-ui-core-1.7.3.min.js",
      "skills/visualize/assets/vendor/floating-ui-core-1.7.3.min.js.LICENSE",
      "skills/visualize/assets/vendor/floating-ui-dom-1.7.4.min.js",
      "skills/visualize/assets/vendor/floating-ui-dom-1.7.4.min.js.LICENSE",
      "skills/visualize/assets/vendor/lucide-1.17.0.js",
      "skills/visualize/assets/vendor/lucide-1.17.0.js.LICENSE",
      "skills/visualize/assets/vendor/d3-7.9.0.min.js",
      "skills/visualize/assets/vendor/d3-7.9.0.min.js.LICENSE",
      "skills/visualize/widgets/calendar.md",
      "skills/visualize/examples/calendar.html",
      "skills/visualize/assets/standalone-host-bridge.js",
      "skills/visualize/assets/standalone-shell.js",
    ],
    requiredRuntimePaths: [],
    stagedPath: "packages/visualize-plugin",
  },
  {
    // browser-use 只携带自己的 client script 与 skill/docs；node_repl MCP runtime 归
    // @ccbuddy/node-repl-host（见上方常量注释）。
    packageName: "@ccbuddy/browser-use-plugin",
    relativePath: "apps/ccbuddy-cli/packages/browser-use-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: browserUseRequiredRuntimePaths,
    runtimeBuildScript: "scripts/build.mjs",
    stagedPath: "packages/browser-use-plugin",
  },
  {
    packageName: "@ccbuddy/ios-simulator-plugin",
    relativePath: "apps/ccbuddy-cli/packages/ios-simulator-plugin",
    requiresRuntime: true,
    requiredRuntimePaths: ["dist/mcp/server.js"],
    runtimeBuildScript: "scripts/build-mcp.mjs",
    stagedPath: "packages/ios-simulator-plugin",
  },
  {
    // 修复原因：restore-legacy-sessions 已注册为官方插件，但 Electron 生产包只会拷贝
    // 这里列出的资源。漏掉它会导致用户生产包首次启动后 plugins list 里看不到该插件。
    packageName: "@ccbuddy/restore-legacy-sessions-plugin",
    relativePath: "apps/ccbuddy-cli/packages/restore-legacy-sessions-plugin",
    requiresRuntime: false,
    stagedPath: "packages/restore-legacy-sessions-plugin",
  },
  {
    packageName: "@ccbuddy/skill-creator-plugin",
    relativePath: "apps/ccbuddy-cli/packages/skill-creator-plugin",
    requiresRuntime: false,
    stagedPath: "packages/skill-creator-plugin",
  },
  {
    packageName: "@ccbuddy/plugin-creator-plugin",
    relativePath: "apps/ccbuddy-cli/packages/plugin-creator-plugin",
    requiresRuntime: false,
    stagedPath: "packages/plugin-creator-plugin",
  },
  {
    // 修复原因：ccbuddy-guide 已注册为官方默认启用内容型插件（见 official-plugin-definitions.ts）。
    // Electron 生产包不是 SEA 路径，官方插件 seed 依赖这里 stage 的 resources/glm/packages/*-plugin；
    // 漏掉它会导致生产桌面包首启 seed 不到该插件，用户拿不到默认启用的配置指南技能。
    packageName: "@ccbuddy/ccbuddy-guide-plugin",
    relativePath: "apps/ccbuddy-cli/packages/ccbuddy-guide-plugin",
    requiresRuntime: false,
    stagedPath: "packages/ccbuddy-guide-plugin",
  },
  {
    // node_repl 宿主：Browser Use 与 Computer Use 共用的 MCP runtime，本轮抽成独立包。
    // 它没有 listing（不进插件市场展示面），但生产包首启 seed 必须拿到它的 dist runtime，
    // 否则 bua/cua 任一开启时都会连不上 node_repl。
    packageName: "@ccbuddy/node-repl-host",
    relativePath: "apps/ccbuddy-cli/packages/node-repl-host",
    requiresRuntime: true,
    requiredRuntimePaths: ["dist/mcp/server.js"],
    runtimeBuildScript: "scripts/build.mjs",
    stagedPath: "packages/node-repl-host",
  },
  {
    // CUA 插件只携带 SDK/skill/docs；node_repl MCP runtime 归 @ccbuddy/node-repl-host。
    packageName: "@ccbuddy/ccbuddy-cua-plugin",
    relativePath: "apps/ccbuddy-cli/packages/ccbuddy-cua-plugin",
    requiresRuntime: false,
    stagedPath: "packages/ccbuddy-cua-plugin",
  },
  {
    // design（默认启用内容型插件）：Electron 生产包靠这里 stage 的目录做首启 seed，漏掉它
    // 生产桌面包就没有设计技能。必需文件与 official-plugin-definitions.ts 的 requiredSeedPaths 一致。
    packageName: "@ccbuddy/design-plugin",
    relativePath: "apps/ccbuddy-cli/packages/design-plugin",
    requiresRuntime: false,
    requiredSeedPaths: [
      "skills/design/SKILL.md",
      "skills/design/references/app.md",
      "skills/design/references/catalog.md",
      "skills/design/references/check.md",
      "skills/design/references/create.md",
      "skills/design/references/deck.md",
      "skills/design/references/design-system.md",
      "skills/design/references/image.md",
      "skills/design/references/interact.md",
      "skills/design/references/motion.md",
      "skills/design/references/page.md",
      "skills/design/references/redesign.md",
      "skills/design/scripts/adapt-canvas.mjs",
      "skills/design/scripts/audit-page.js",
      "skills/design/scripts/audit.mjs",
      "skills/design/scripts/design-lint.mjs",
      "skills/design/scripts/design-tokens.mjs",
      "skills/design/scripts/import-design-system.mjs",
      "skills/design/scripts/probe.js",
      "hooks/hooks.json",
      "hooks/run-hook.cmd",
      "hooks/design-rules",
    ],
    requiredRuntimePaths: [],
    stagedPath: "packages/design-plugin",
  },
  // superpowers 已从内置插件下线，改走 UI 推荐区按需安装；这里不再 stage 它的资源。
];
