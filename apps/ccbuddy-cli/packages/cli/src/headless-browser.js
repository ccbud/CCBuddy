import { createManagedCdpBrowserRuntime, } from "@ccbuddy/adapters/browser";
import { loadCliPlaywrightChromium } from "./sea-playwright-runtime.js";
export function createCliHeadlessBrowserRuntime(options, deps) {
    if (options.browserUse !== "headless")
        return undefined;
    const factory = deps.createManagedCdpBrowserRuntime ?? createManagedCdpBrowserRuntime;
    return factory({
        env: deps.env,
        executablePath: options.browserExecutable,
        storageStatePath: options.browserState?.path,
        loadPlaywright: loadCliPlaywrightChromium,
    });
}
