import { formatAvailableCommandCenterModes, isSwitchableCommandCenterMode, } from "../modes.js";
export async function handleModeCommand(args, deps) {
    const current = deps.getMode?.() ?? "build";
    if (args.length === 0) {
        return {
            mode: current,
            response: `Current mode: ${current}. Available modes: ${formatAvailableCommandCenterModes()}.`,
        };
    }
    const requested = args.toLowerCase();
    if (!isSwitchableCommandCenterMode(requested)) {
        return {
            mode: current,
            response: `Unsupported mode: ${args}. Available modes: ${formatAvailableCommandCenterModes()}.`,
        };
    }
    if (!deps.setMode) {
        return {
            mode: current,
            response: "Mode switching is not available in this client.",
        };
    }
    const next = await deps.setMode(requested);
    return {
        mode: next,
        response: `Mode switched to ${next}.`,
    };
}
