import { buildCustomCommandPrompt } from "../../command-center-custom.js";
import { attachCurrentSessionMetadata } from "../metadata.js";
export async function handleCustomCommand(name, args, deps, options) {
    const prompt = await buildCustomCommandPrompt(name, args, deps);
    if (!prompt)
        return undefined;
    const app = await deps.getApp();
    const result = await app.submitPrompt(prompt, options);
    return attachCurrentSessionMetadata(result, deps, app);
}
