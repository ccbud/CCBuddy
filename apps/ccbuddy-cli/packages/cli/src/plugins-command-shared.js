import { createInterface } from "node:readline";
/**
 * CLI 依赖名 → bootstrap 导出名。测试按依赖名注入假实现；生产路径按导出名懒加载 bootstrap，
 * 避免 `ccbuddy plugins list` 这类轻命令把整个 bootstrap 图提前拉起来。
 */
export const BOOTSTRAP_EXPORTS = {
    addMarketplace: "addCCbuddyPluginMarketplace",
    getPluginsOverview: "getCCbuddyPluginsOverview",
    installPlugin: "installCCbuddyMarketplacePlugin",
    listPlugins: "listCCbuddyPlugins",
    removeMarketplace: "removeCCbuddyPluginMarketplace",
    setPluginEnabled: "setCCbuddyPluginEnabled",
    uninstallPlugin: "uninstallCCbuddyMarketplacePlugin",
    updateMarketplace: "updateCCbuddyPluginMarketplace",
    updatePlugin: "updateCCbuddyMarketplacePlugin",
    validatePluginPath: "validateCCbuddyPluginPath",
};
/** 参数用法错误：调用方打印 message + usage 并以 1 退出。 */
export class PluginsUsageError extends Error {
}
export function requireOne(rest) {
    const [value] = rest;
    if (rest.length !== 1 || !value || value.trim().length === 0)
        throw new PluginsUsageError();
    return value.trim();
}
export async function resolveDep(deps, key) {
    const override = deps[key];
    if (override)
        return override;
    const bootstrap = deps.loadBootstrapModule ?? (() => import("@ccbuddy/bootstrap"));
    return (await bootstrap())[BOOTSTRAP_EXPORTS[key]];
}
export function baseOptions(deps) {
    return {
        env: deps.env ?? process.env,
        logger: deps.logger,
        projectConfigPath: deps.projectConfigPath,
        skipUserConfig: deps.skipUserConfig,
        userConfigPath: deps.userConfigPath,
        workingDirectory: (deps.cwd ?? process.cwd)(),
    };
}
export function resolveScope(value) {
    if (value === undefined)
        return undefined;
    if (value === "user")
        return "user";
    if (value === "project")
        return "workspace";
    if (value === "local") {
        throw new PluginsUsageError("Scope 'local' is not supported by CCbuddy. Use: user, project");
    }
    throw new PluginsUsageError(`Invalid scope '${value}'. Use: user, project`);
}
export function splitPluginIdentifier(value) {
    const at = value.lastIndexOf("@");
    if (at <= 0 || at === value.length - 1)
        return { name: value };
    return { name: value.slice(0, at), marketplace: value.slice(at + 1) };
}
export function hasErrors(diagnostics) {
    return diagnostics.some((diagnostic) => diagnostic.severity === "error");
}
/** 裸 name 在已加载插件（内置 + 已安装）里唯一匹配才放行；多个同名必须带 @marketplace。 */
export async function resolveLoadedPluginId(deps, identifier) {
    if (splitPluginIdentifier(identifier).marketplace)
        return identifier;
    const outcome = await (await resolveDep(deps, "listPlugins"))(baseOptions(deps));
    const matches = outcome.plugins.filter((plugin) => plugin.name === identifier);
    if (matches.length === 1 && matches[0])
        return matches[0].id;
    if (matches.length > 1)
        throw ambiguousPluginError(matches.map((plugin) => plugin.id));
    throw new Error(`Plugin not found: ${identifier}`);
}
export function ambiguousPluginError(ids) {
    return new Error(`Plugin name is ambiguous, use <plugin>@<marketplace>: ${ids.join(", ")}`);
}
export function confirmUninstall(ctx, pluginId) {
    return new Promise((resolvePrompt) => {
        const rl = createInterface({ input: ctx.stdin, output: ctx.stdout });
        rl.question(`Uninstall ${pluginId}? [y/N] `, (answer) => {
            rl.close();
            resolvePrompt(/^y(es)?$/i.test(answer.trim()));
        });
    });
}
export function reportPluginsError(ctx, options, error) {
    const message = error instanceof Error ? error.message : String(error);
    ctx.stderr.write(`Error: ${message}\n`);
    if (options.verbose && error instanceof Error && error.stack) {
        ctx.stderr.write(`${error.stack}\n`);
    }
    return 1;
}
