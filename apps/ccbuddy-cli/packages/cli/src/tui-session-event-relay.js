export function createTuiSessionEventRelay(input) {
    const sinks = new Set();
    let detachCurrent;
    const detach = () => {
        detachCurrent?.();
        detachCurrent = undefined;
    };
    const reattach = () => {
        detach();
        if (sinks.size === 0)
            return;
        const subscribe = input.readSubscriber(input.currentRuntime());
        detachCurrent = subscribe?.({
            onSessionEvent: (event) => {
                // 直接遍历 Set：JS 的 Set 迭代对「遍历中删除」是安全的（已删未访问的条目会被跳过），
                // 所以 sink 在回调里退订不会破坏本次扇出，也不该再收到这一条。
                for (const sink of sinks)
                    sink(event);
            },
        });
    };
    return {
        addSink: (sink) => {
            sinks.add(sink);
            if (sinks.size === 1)
                reattach();
            return () => {
                sinks.delete(sink);
                if (sinks.size === 0)
                    detach();
            };
        },
        reattach,
        detach,
        isAttached: () => detachCurrent !== undefined,
    };
}
