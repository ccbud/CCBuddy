import { spawn } from "node:child_process";
const GREP_DEFAULT_ARGS = [
    "-G",
    "-I",
    "--exclude-dir=.git",
    "--exclude-dir=.svn",
    "--exclude-dir=.hg",
    "--exclude-dir=.bzr",
    "--exclude-dir=.jj",
    "--exclude-dir=.sl",
];
const GREP_BYPASS_PATTERNS = [
    /^-.*-filter.*$/u,
    /^-.*-pager.*$/u,
    /^-.*-view.*$/u,
    /^-.*-format-open.*$/u,
    /^-.*-config.*$/u,
    /^---.*$/u,
    /^-@.*$/u,
    /^-.*-save-config.*$/u,
    // ugrep 的 -z/-Z 与 GNU grep 的 null-data 语义不同；这些参数必须绕回系统 grep。
    /^-[Zz].*$/u,
    /^-[^-].*[Zz].*$/u,
    /^--null$/u,
    /^--null-data$/u,
];
const OUTPUT_CLOSED_ERROR_CODES = new Set(["EPIPE", "EIO", "ENXIO", "EBADF"]);
const SIGTERM_TO_SIGKILL_MS = 750;
const DEFAULT_ABORT_EXIT_CODE = 130;
const SIGNAL_EXIT_CODES = {
    SIGHUP: 129,
    SIGINT: 130,
    SIGTERM: 143,
};
const EMBEDDED_SEARCH_ABORT_REASON = "embedded-search-abort";
export async function runEmbeddedSearchCli(argv, io) {
    const command = argv[0];
    if (command !== "find" && command !== "grep") {
        io.stderr.write(`unsupported embedded search command: ${command ?? ""}\n`);
        return 2;
    }
    const abortScope = createEmbeddedSearchAbortScope(io.signal);
    try {
        return await runNativeSearchCommand(command, argv.slice(1), io, abortScope.signal);
    }
    finally {
        abortScope.dispose();
    }
}
export function resolveNativeSearchArgs(command, args) {
    if (command !== "grep")
        return [...args];
    if (args.some(isGrepBypassArgument))
        return [...args];
    return [...GREP_DEFAULT_ARGS, ...args];
}
function runNativeSearchCommand(command, args, io, signal) {
    return new Promise((resolve) => {
        if (signal.aborted) {
            resolve(exitCodeForAbortSignal(signal));
            return;
        }
        const child = spawn(command, resolveNativeSearchArgs(command, args), {
            cwd: io.cwd,
            stdio: ["pipe", "pipe", "pipe"],
            windowsHide: true,
        });
        let settled = false;
        let childExited = false;
        let forceKillTimer;
        let terminationRequested = false;
        let stdoutClosed = false;
        let stderrClosed = false;
        const cleanupRuntimeListeners = () => {
            io.stdout.off?.("error", onStdoutError);
            io.stderr.off?.("error", onStderrError);
            signal.removeEventListener("abort", onAbort);
        };
        const settle = (exitCode) => {
            if (settled)
                return;
            settled = true;
            cleanupRuntimeListeners();
            resolve(exitCode);
        };
        const requestChildTermination = () => {
            if (terminationRequested || childExited)
                return;
            terminationRequested = true;
            forceKillTimer = terminateNativeSearchChild(child, () => childExited);
        };
        const onAbort = () => {
            // embedded search 的真实搜索进程由 __internal-search 再 spawn；
            // 不能只依赖外层 Bash 的进程树清理，否则 remote/大仓库搜索取消时 native find/grep 可能残留。
            requestChildTermination();
        };
        // internal grep 常被模型放进 `grep ... | head` 管道里；下游读够后会关闭 stdout。
        // 原生 grep/ugrep 会安静处理这种 SIGPIPE，Node 转发层也必须吞掉 EPIPE 并停止子进程，避免栈污染工具结果。
        const stopAfterStdoutClosed = () => {
            stdoutClosed = true;
            requestChildTermination();
            settle(0);
        };
        const onStdoutError = (error) => {
            if (isOutputClosedError(error)) {
                stopAfterStdoutClosed();
            }
        };
        const onStderrError = (error) => {
            if (isOutputClosedError(error)) {
                stderrClosed = true;
            }
        };
        io.stdout.on?.("error", onStdoutError);
        io.stderr.on?.("error", onStderrError);
        signal.addEventListener("abort", onAbort, { once: true });
        if (signal.aborted) {
            onAbort();
        }
        child.stdout.on("data", (chunk) => {
            if (stdoutClosed || io.stdout.destroyed)
                return;
            try {
                io.stdout.write(chunk);
            }
            catch (error) {
                if (isOutputClosedError(error)) {
                    stopAfterStdoutClosed();
                    return;
                }
                throw error;
            }
        });
        child.stderr.on("data", (chunk) => {
            if (stderrClosed || io.stderr.destroyed)
                return;
            try {
                io.stderr.write(chunk);
            }
            catch (error) {
                if (isOutputClosedError(error)) {
                    stderrClosed = true;
                    return;
                }
                throw error;
            }
        });
        child.on("error", (error) => {
            if (settled)
                return;
            if (!stderrClosed && !io.stderr.destroyed) {
                try {
                    io.stderr.write(`failed to run embedded ${command}: ${error.message}\n`);
                }
                catch (writeError) {
                    if (!isOutputClosedError(writeError)) {
                        throw writeError;
                    }
                }
            }
            settle(signal.aborted ? exitCodeForAbortSignal(signal) : error.code === "ENOENT" ? 127 : 1);
        });
        child.on("close", (code, childSignal) => {
            childExited = true;
            if (forceKillTimer) {
                clearTimeout(forceKillTimer);
            }
            settle(signal.aborted ? exitCodeForAbortSignal(signal) : code ?? (childSignal ? 128 : 1));
        });
        if (io.stdin) {
            io.stdin.pipe(child.stdin);
            child.stdin.on("error", () => {
                // Native grep/find may exit before consuming stdin, which is normal for file-only commands.
            });
        }
        else {
            child.stdin.end();
        }
    });
}
function createEmbeddedSearchAbortScope(parentSignal) {
    const controller = new AbortController();
    const processListeners = [];
    let disposed = false;
    const abortFromParent = () => {
        if (controller.signal.aborted)
            return;
        controller.abort(parentSignal?.reason);
    };
    if (parentSignal?.aborted) {
        abortFromParent();
    }
    else {
        parentSignal?.addEventListener("abort", abortFromParent, { once: true });
    }
    if (!controller.signal.aborted) {
        for (const signal of embeddedSearchShutdownSignals()) {
            const listener = () => {
                if (!controller.signal.aborted) {
                    controller.abort(createSignalAbortReason(signal));
                }
            };
            process.once(signal, listener);
            processListeners.push([signal, listener]);
        }
    }
    return {
        dispose: () => {
            if (disposed)
                return;
            disposed = true;
            parentSignal?.removeEventListener("abort", abortFromParent);
            for (const [signal, listener] of processListeners) {
                process.off(signal, listener);
            }
        },
        signal: controller.signal,
    };
}
function terminateNativeSearchChild(child, hasExited) {
    const pid = child.pid;
    if (!pid) {
        child.kill("SIGTERM");
        return undefined;
    }
    if (process.platform === "win32") {
        const killer = spawn("taskkill", ["/pid", String(pid), "/T", "/F"], {
            stdio: "ignore",
            windowsHide: true,
        });
        killer.once("error", () => child.kill("SIGKILL"));
        return undefined;
    }
    // native find/grep 是 __internal-search 的直接子进程；
    // 保持它在外层 Bash 进程组内，让 Bash runner 的二段清理仍能兜住，同时 wrapper 自己定点终止直接 child。
    child.kill("SIGTERM");
    const timer = setTimeout(() => {
        if (hasExited())
            return;
        child.kill("SIGKILL");
    }, SIGTERM_TO_SIGKILL_MS);
    timer.unref();
    return timer;
}
function createSignalAbortReason(signal) {
    return {
        exitCode: SIGNAL_EXIT_CODES[signal] ?? DEFAULT_ABORT_EXIT_CODE,
        kind: EMBEDDED_SEARCH_ABORT_REASON,
        signal,
    };
}
function exitCodeForAbortSignal(signal) {
    return isEmbeddedSearchAbortReason(signal.reason)
        ? signal.reason.exitCode
        : DEFAULT_ABORT_EXIT_CODE;
}
function isEmbeddedSearchAbortReason(reason) {
    return (typeof reason === "object" &&
        reason !== null &&
        "kind" in reason &&
        reason.kind === EMBEDDED_SEARCH_ABORT_REASON &&
        "exitCode" in reason &&
        typeof reason.exitCode === "number");
}
function embeddedSearchShutdownSignals() {
    return process.platform === "win32" ? ["SIGINT", "SIGTERM"] : ["SIGINT", "SIGTERM", "SIGHUP"];
}
function isGrepBypassArgument(argument) {
    return GREP_BYPASS_PATTERNS.some((pattern) => pattern.test(argument));
}
function isOutputClosedError(error) {
    return (typeof error === "object" &&
        error !== null &&
        "code" in error &&
        typeof error.code === "string" &&
        OUTPUT_CLOSED_ERROR_CODES.has(error.code));
}
