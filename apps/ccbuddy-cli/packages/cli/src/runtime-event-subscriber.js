/**
 * 从 `unknown` 上动态读一个函数成员。
 *
 * 收 `unknown` 并动态探属性，**不是**为了防御真实的 `AgentRuntime`（那上面这些成员都是
 * 必选的），而是因为 `RunDependencies.createCCbuddyApp` 是公开注入点（cli-types.ts 的注释
 * 写着"tests, embedders"），替身的 runtime 可以是任意形状。对着必选成员写 `?.` 会被 TS
 * 判成恒真条件——所以边界在这里，用一次显式的动态读取表达。
 */
export const readRuntimeFunction = (source, key) => {
    if (!source || typeof source !== "object")
        return undefined;
    const value = source[key];
    return typeof value === "function" ? value : undefined;
};
/**
 * 读出 runtime 的跨回合事件订阅。
 *
 * **不静默降级**：拿不到订阅就返回 `undefined`，调用方退回 per-turn `onEvent`（单回合可见，
 * 与改动前一致）。这是"这个宿主没有这个能力"的诚实答复，而不是假装订阅上了。
 */
export const readRuntimeEventSubscriber = (runtime) => {
    const subscribe = readRuntimeFunction(runtime, "subscribeEvents");
    if (!subscribe)
        return undefined;
    return (sink) => {
        const detach = subscribe.call(runtime, sink);
        return typeof detach === "function" ? detach : () => undefined;
    };
};
