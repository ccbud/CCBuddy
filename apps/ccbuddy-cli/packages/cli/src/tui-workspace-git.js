import { spawn } from "node:child_process";
const GIT_COMMAND = "git";
const GIT_BRANCH_ARGS = ["symbolic-ref", "--quiet", "--short", "HEAD"];
const DEFAULT_GIT_TIMEOUT_MS = 750;
const DEFAULT_GIT_OUTPUT_LIMIT_BYTES = 512;
const DETACHED_HEAD_LABEL = "HEAD";
export async function resolveWorkspaceGitBranch(options) {
    const maxOutputBytes = options.maxOutputBytes ?? DEFAULT_GIT_OUTPUT_LIMIT_BYTES;
    const timeoutMs = options.timeoutMs ?? DEFAULT_GIT_TIMEOUT_MS;
    const runCommand = options.runCommand ?? runGitCommand;
    const result = await runCommand(GIT_COMMAND, ["-C", options.workspaceDirectory, ...GIT_BRANCH_ARGS], {
        maxOutputBytes,
        timeoutMs,
    }).catch(() => ({ exitCode: -1, stdout: "" }));
    if (result.exitCode !== 0)
        return undefined;
    const branch = result.stdout.trim().split(/\r?\n/, 1)[0]?.trim();
    if (!branch || branch === DETACHED_HEAD_LABEL)
        return undefined;
    return branch;
}
async function runGitCommand(file, args, options) {
    return await new Promise((resolve) => {
        let child;
        try {
            child = spawn(file, args, {
                stdio: ["ignore", "pipe", "ignore"],
                windowsHide: true,
            });
        }
        catch {
            resolve({ exitCode: -1, stdout: "" });
            return;
        }
        let stdout = "";
        let settled = false;
        const timeout = setTimeout(() => {
            child.kill();
            finish({ exitCode: -1, stdout });
        }, options.timeoutMs);
        const finish = (result) => {
            if (settled)
                return;
            settled = true;
            clearTimeout(timeout);
            resolve(result);
        };
        child.stdout?.on("data", (chunk) => {
            stdout += chunk.toString("utf8");
            if (Buffer.byteLength(stdout, "utf8") > options.maxOutputBytes) {
                child.kill();
                finish({ exitCode: -1, stdout });
            }
        });
        child.on("error", () => finish({ exitCode: -1, stdout }));
        child.on("close", (exitCode) => finish({ exitCode, stdout }));
    });
}
