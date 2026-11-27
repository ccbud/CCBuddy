import { parseArgs } from "node:util";
import { resolve } from "node:path";
const USAGE = `Usage:
  ccbuddy hooks trust status [--workspace <path-or-identity>] [--json]
  ccbuddy hooks trust review [--workspace <path-or-identity>] [--json]
  ccbuddy hooks trust grant --workspace <path-or-identity> --hook-digest <sha256> [--hook-digest <sha256> ...]
  ccbuddy hooks trust grant --workspace <path-or-identity> --all-current --bundle-digest <sha256>
  ccbuddy hooks trust revoke --workspace <path-or-identity> [--hook-digest <sha256> ... | --all]
`;
export async function runHooksCommand(ctx, deps, version) {
    if (ctx.argv[1] !== "trust")
        return fail(ctx, `Unknown hooks command: ${ctx.argv[1] ?? ""}`);
    let parsed;
    try {
        parsed = parseTrustArgs(ctx.argv.slice(2));
    }
    catch (error) {
        return fail(ctx, error instanceof Error ? error.message : String(error));
    }
    if (parsed.values.help) {
        ctx.stdout.write(USAGE);
        return 0;
    }
    const action = parsed.positionals[0] ?? "status";
    if (!isAction(action) || parsed.positionals.length > 1) {
        return fail(ctx, `Unknown hooks trust command: ${action}`);
    }
    const target = resolveTarget(parsed.values.workspace, (deps.cwd ?? process.cwd)(), deps.userConfigPath);
    const bootstrap = deps.loadBootstrapModule ?? (() => import("@ccbuddy/bootstrap"));
    try {
        let status;
        if (action === "status" || action === "review") {
            const inspect = deps.inspectWorkspaceHookTrust ?? (await bootstrap()).inspectWorkspaceHookTrust;
            status = await inspect(target);
        }
        else if (action === "grant") {
            const grant = deps.grantWorkspaceHookTrust ?? (await bootstrap()).grantWorkspaceHookTrust;
            status = await grant({
                ...target,
                hookDeclarationDigests: parsed.values["hook-digest"],
                allCurrent: parsed.values["all-current"] === true,
                bundleDigest: parsed.values["bundle-digest"],
                appVersion: version,
            });
        }
        else {
            const revoke = deps.revokeWorkspaceHookTrustCli ?? (await bootstrap()).revokeWorkspaceHookTrustCli;
            status = await revoke({
                ...target,
                hookDeclarationDigests: parsed.values["hook-digest"],
                all: parsed.values.all === true,
            });
        }
        ctx.stdout.write(parsed.values.json ? `${JSON.stringify(status, null, 2)}\n` : formatHuman(status, action));
        return 0;
    }
    catch (error) {
        const reasonCode = error instanceof Error ? error.message : String(error);
        // 因入口脚本不存在或无法读取被整体拒绝时，两种输出都列出是哪些条目（spec §12.9）。
        const unavailableItems = error
            ?.unavailableItems;
        if (parsed.values.json) {
            ctx.stdout.write(`${JSON.stringify({
                accepted: false,
                reasonCode,
                ...(Array.isArray(unavailableItems) ? { unavailableItems } : {}),
            }, null, 2)}\n`);
        }
        else {
            ctx.stderr.write(`Error: ${reasonCode}\n`);
            if (Array.isArray(unavailableItems)) {
                ctx.stderr.write(`Entry script missing or unreadable:\n${unavailableItems.map((item) => `  ${String(item)}`).join("\n")}\n`);
            }
        }
        return 1;
    }
}
function parseTrustArgs(args) {
    return parseArgs({
        allowPositionals: true,
        args,
        options: {
            workspace: { type: "string" },
            "hook-digest": { type: "string", multiple: true },
            "all-current": { type: "boolean" },
            "bundle-digest": { type: "string" },
            all: { type: "boolean" },
            json: { type: "boolean" },
            help: { type: "boolean", short: "h" },
        },
    });
}
function resolveTarget(value, cwd, userConfigPath) {
    const selected = value?.trim();
    const identity = selected && looksLikeWorkspaceIdentity(selected) ? selected : undefined;
    return {
        workspacePath: identity ? resolve(cwd) : selected ? resolve(cwd, selected) : resolve(cwd),
        ...(identity ? { workspaceIdentity: identity } : {}),
        ...(userConfigPath ? { userConfigPath } : {}),
    };
}
function looksLikeWorkspaceIdentity(value) {
    return /^(?:local|remote|ssh|container|wsl):/u.test(value);
}
/**
 * 提示命令里的 `--workspace` 参数。受管 worktree 的 workspaceIdentity 是 Trust identity（源仓库路径，D23），
 * 直接回填会让后续 grant 去审核源仓库的 bundle；本地路径一律回填当前 workspacePath，远程 identity 原样。
 */
export function workspaceTrustCommandArgument(status) {
    return looksLikeWorkspaceIdentity(status.workspaceIdentity)
        ? status.workspaceIdentity
        : status.workspacePath;
}
function formatHuman(status, action) {
    const lines = [
        `Workspace Hook Trust (${action})`,
        `workspace: ${status.workspaceIdentity}`,
        `path: ${status.workspacePath}`,
        `bundle: ${status.bundleDigest ?? "none"}`,
        `state: ${status.reasonCode}`,
    ];
    if (status.items.length === 0)
        lines.push("No Workspace Hook declarations found.");
    for (const [index, item] of status.items.entries()) {
        lines.push(`${index + 1}. [${item.trustState}] [${item.configuredEnabled ? "enabled" : "disabled"}] ${item.event}${item.matcher ? ` / ${item.matcher}` : ""}`, `   ${item.displayCommand}`, `   source: ${item.sourcePath}`, `   digest: ${item.hookDeclarationDigest}`);
    }
    if (status.reasonCode === "workspace_hooks_pending_trust" && status.bundleDigest) {
        lines.push("Pretrust exact declarations with:", `  ccbuddy hooks trust grant --workspace ${quote(workspaceTrustCommandArgument(status))} --hook-digest <sha256>`);
        // 含入口不可用的启用条目时 --all-current 必然被拒，不再推荐。
        if (!status.items.some((item) => item.configuredEnabled && item.trustState === "blocked_untrusted")) {
            lines.push("Or trust every currently enabled declaration in this exact bundle with:", `  ccbuddy hooks trust grant --workspace ${quote(workspaceTrustCommandArgument(status))} --all-current --bundle-digest ${status.bundleDigest}`);
        }
    }
    if (status.reasonCode === "workspace_hooks_trust_store_corrupt") {
        // 损坏 store 下 grant/revoke 都会被拒绝；恢复指引必须是修复文件本身。
        lines.push("The persistent trust store is corrupt; grant/revoke are rejected until it is fixed.", "The corrupted file was moved aside as workspace-hook-trust-v1.json.corrupt-<timestamp>.", "Recovery: restore it from backup, or remove the leftover *.corrupt-* file so a fresh store is created, then re-run grant.");
    }
    return `${lines.join("\n")}\n`;
}
function quote(value) {
    return JSON.stringify(value);
}
function isAction(value) {
    return value === "status" || value === "review" || value === "grant" || value === "revoke";
}
function fail(ctx, message) {
    ctx.stderr.write(`${message}\n${USAGE}`);
    return 1;
}
