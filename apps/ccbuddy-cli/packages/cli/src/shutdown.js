import { takeCoverage } from "node:v8";
const DEFAULT_SHUTDOWN_CLEANUP_TIMEOUT_MS = 2_000;
export const DEFAULT_CLI_CLEANUP_TIMEOUT_MS = 6_000;
const DEFAULT_CLI_EXIT_WATCHDOG_TIMEOUT_MS = 1_000;
const SIGNAL_EXIT_CODES = {
    SIGHUP: 129,
    SIGINT: 130,
    SIGTERM: 143,
};
export function registerCliShutdownHandlers(options) {
    const signalTarget = options.process ?? process;
    const exitProcess = options.exitProcess ?? ((code) => process.exit(code));
    const cleanupTimeoutMs = Math.max(0, Math.trunc(options.cleanupTimeoutMs ?? DEFAULT_SHUTDOWN_CLEANUP_TIMEOUT_MS));
    const signals = shutdownSignals(signalTarget.platform);
    const listeners = [];
    let disposed = false;
    let shuttingDown = false;
    const unregister = () => {
        if (disposed)
            return;
        disposed = true;
        for (const [signal, listener] of listeners) {
            signalTarget.off(signal, listener);
        }
    };
    const shutdown = async (signal) => {
        if (shuttingDown)
            return;
        shuttingDown = true;
        // detached shell processes form their own process group, so parent
        // process shutdown must explicitly close the app before Node exits.
        options.abort?.(signal);
        await runCliCleanupWithTimeout(options.cleanup, cleanupTimeoutMs);
        await flushE2ECoverage();
        unregister();
        exitProcess(exitCodeForSignal(signal));
    };
    for (const signal of signals) {
        const listener = () => {
            void shutdown(signal);
        };
        signalTarget.once(signal, listener);
        listeners.push([signal, listener]);
    }
    return unregister;
}
export async function flushE2ECoverage() {
    if (process.env.CCBUDDY_E2E_COVERAGE !== "1" || !process.env.NODE_V8_COVERAGE?.trim()) {
        return;
    }
    try {
        // Agent shutdown 最终调用 process.exit，SIGTERM 路径不会可靠触发
        // NODE_V8_COVERAGE 的自动落盘；只在 E2E coverage 模式下显式刷新。
        takeCoverage();
        // takeCoverage 会把写盘交给 V8 后台任务；立即 process.exit 偶发只留下 readiness
        // marker。coverage 模式留出短暂落盘窗口，普通 CLI shutdown 不增加延迟。
        await new Promise((resolve) => setTimeout(resolve, 500));
    }
    catch {
        // coverage 是诊断产物，写盘失败不能阻塞 CLI 的既有退出流程。
    }
}
function shutdownSignals(platform) {
    return platform === "win32" ? ["SIGINT", "SIGTERM"] : ["SIGINT", "SIGTERM", "SIGHUP"];
}
function exitCodeForSignal(signal) {
    return SIGNAL_EXIT_CODES[signal] ?? 1;
}
export async function runCliCleanupWithTimeout(cleanup, timeoutMs) {
    let timeout;
    try {
        const cleanupPromise = Promise.resolve().then(cleanup);
        if (timeoutMs === 0) {
            await cleanupPromise;
            return;
        }
        await Promise.race([
            cleanupPromise,
            new Promise((resolve) => {
                timeout = setTimeout(resolve, timeoutMs);
                timeout.unref?.();
            }),
        ]);
    }
    catch {
        // Shutdown cleanup is best-effort; exiting should not be blocked by a
        // failing adapter close path.
    }
    finally {
        if (timeout)
            clearTimeout(timeout);
    }
}
export function scheduleCliExitWatchdog(options) {
    const exitProcess = options.exitProcess ?? ((code) => process.exit(code));
    const timeoutMs = Math.max(1, Math.trunc(options.timeoutMs ?? DEFAULT_CLI_EXIT_WATCHDOG_TIMEOUT_MS));
    const timer = setTimeout(() => {
        // 正常 run() 已完成后仍可能残留未知 pipe/socket handle。watchdog
        // 只在 event loop 到 deadline 仍未耗尽时执行，因此不会延迟自然退出路径。
        void flushE2ECoverage().finally(() => exitProcess(options.exitCode));
    }, timeoutMs);
    timer.unref?.();
    return () => clearTimeout(timer);
}
