import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

export const MCP_DIAGNOSTIC_PYTHON = "e2e_python_dependency";
export const MCP_DIAGNOSTIC_COMMAND = "e2e_missing_command";
export const MCP_DIAGNOSTIC_NODE = "plugin:e2e-startup-diagnostics:node";

export async function prepareMcpFailureGuidanceFixture(options: {
  specs: string[];
  credentialsFile: string;
  settingsFile: string;
  workspacePath: string;
}): Promise<(() => Promise<void>) | null> {
  if (!options.specs.some((spec) => spec.endsWith("mcp-failure-guidance.test.ts"))) return null;
  const storageRoot = dirname(dirname(options.credentialsFile));
  const cliRoot = join(storageRoot, "cli");
  const marker = join(storageRoot, "mcp-diagnostic-recovered");
  const script = resolve("test/e2e/fixtures/mcp/startup-diagnostic-server.mjs");
  const pluginRoot = join(cliRoot, "e2e-fixtures", "e2e-startup-diagnostics");
  await mkdir(join(pluginRoot, ".ccbuddy-plugin"), { recursive: true });
  await writeFile(
    join(pluginRoot, ".ccbuddy-plugin", "plugin.json"),
    JSON.stringify({
      name: "e2e-startup-diagnostics",
      version: "0.0.0",
      mcpServers: {
        node: {
          type: "stdio",
          command: process.execPath,
          args: [script, "node"],
          protocolVersion: "legacy",
        },
      },
    }),
  );
  const pluginId = "e2e-startup-diagnostics@e2e-fixture";
  await mkdir(join(cliRoot, "plugins"), { recursive: true });
  await writeFile(
    join(cliRoot, "plugins", "installed_plugins.json"),
    JSON.stringify({
      version: 1,
      plugins: [
        {
          id: pluginId,
          name: "e2e-startup-diagnostics",
          installPath: pluginRoot,
          marketplace: "e2e-fixture",
          scope: "user",
          version: "0.0.0",
          installedAt: "2026-10-30T00:00:00.000Z",
          updatedAt: "2026-10-30T00:00:00.000Z",
        },
      ],
    }),
  );
  const configPath = join(cliRoot, "config.json");
  const config = JSON.parse(
    await readFile(configPath, "utf8").catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "ENOENT") throw error;
      return "{}";
    }),
  );
  config.plugins = {
    ...config.plugins,
    enabledPlugins: { ...config.plugins?.enabledPlugins, [pluginId]: true },
  };
  config.mcp = {
    ...config.mcp,
    servers: {
      ...config.mcp?.servers,
      [MCP_DIAGNOSTIC_PYTHON]: {
        type: "stdio",
        command: process.execPath,
        args: [script, "python", marker],
        protocolVersion: "legacy",
      },
      [MCP_DIAGNOSTIC_COMMAND]: {
        type: "stdio",
        command: join(cliRoot, "missing-mcp-executable"),
        protocolVersion: "legacy",
      },
    },
  };
  await writeFile(configPath, JSON.stringify(config));
  // 桌面诊断 fixture 只落盘插件与配置，随隔离 HOME 一起清理。
  return async () => {};
}
