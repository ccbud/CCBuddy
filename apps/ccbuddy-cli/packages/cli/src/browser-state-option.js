import { resolve } from "node:path";
import { BrowserStateFileError, loadBrowserStorageState, resolveDefaultBrowserStatePath, } from "@ccbuddy/adapters/browser";
export const BROWSER_STATE_REQUIRES_HEADLESS_ERROR = "--browser-state and --no-browser-state require --browser-use=headless.";
export const BROWSER_STATE_CONFLICT_ERROR = "--browser-state cannot be used with --no-browser-state.";
const DEFAULT_STATE_FIX_HINT = "Fix the file or pass --no-browser-state.";
const LIST_SEPARATOR = ", ";
const OCTAL_RADIX = 8;
const OCTAL_MODE_WIDTH = 4;
export function validateBrowserStateFlags(input) {
    const requested = input.explicitPath !== undefined || input.disabled;
    if (requested && input.browserUse !== "headless")
        return BROWSER_STATE_REQUIRES_HEADLESS_ERROR;
    if (input.explicitPath !== undefined && input.disabled)
        return BROWSER_STATE_CONFLICT_ERROR;
    return undefined;
}
export async function resolveBrowserStateSelection(input) {
    if (input.disabled)
        return { ok: true, notices: [] };
    const selection = input.explicitPath === undefined
        ? { source: "default", path: resolveDefaultBrowserStatePath(input.env, input.platform) }
        : { source: "explicit", path: resolve(input.launchCwd, input.explicitPath) };
    let loaded;
    try {
        loaded = await loadBrowserStorageState(selection.path, { platform: input.platform });
    }
    catch (error) {
        if (!(error instanceof BrowserStateFileError))
            throw error;
        if (selection.source === "default" && error.code === "missing") {
            return { ok: true, notices: [] };
        }
        return { ok: false, error: formatFileError(error, selection.source) };
    }
    const looseMode = loaded.looseMode === undefined
        ? undefined
        : loaded.looseMode.toString(OCTAL_RADIX).padStart(OCTAL_MODE_WIDTH, "0");
    return {
        ok: true,
        selection,
        notices: buildNotices(selection, loaded.unknownFields, looseMode),
        logFields: {
            source: selection.source,
            ...loaded.summary,
            unknownFieldCount: loaded.unknownFields.length,
            ...(looseMode === undefined ? {} : { looseMode }),
        },
    };
}
function formatFileError(error, source) {
    const fields = error.code === "invalid_schema" && error.issues.length > 0
        ? ` (fields: ${error.issues.join(LIST_SEPARATOR)})`
        : "";
    const hint = source === "default" ? ` ${DEFAULT_STATE_FIX_HINT}` : "";
    return `${error.message}: ${error.path}${fields}.${hint}`;
}
function buildNotices(selection, unknownFields, looseMode) {
    const notices = [];
    if (selection.source === "default") {
        notices.push(`Loaded default browser state from ${selection.path}. Pass --no-browser-state to skip it.`);
    }
    if (unknownFields.length > 0) {
        notices.push(`Browser state file has fields that will be ignored: ${unknownFields.join(LIST_SEPARATOR)}.`);
    }
    if (looseMode !== undefined) {
        notices.push(`Browser state file is readable by other users (mode ${looseMode}). Run: chmod 600 ${selection.path}`);
    }
    return notices;
}
