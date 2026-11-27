export function normalizeTuiPromptInput(input) {
    if (typeof input === "string")
        return { text: input };
    return input;
}
export function attachCurrentSessionMetadata(result, deps, app) {
    return {
        ...result,
        locale: result.locale ?? app?.getLocale?.(),
        mode: result.mode ?? deps.getMode?.(),
        model: result.model ?? app?.getModel?.(),
        theme: result.theme ?? app?.getTheme?.(),
        thoughtLevel: result.thoughtLevel ?? app?.getThoughtLevel?.(),
    };
}
