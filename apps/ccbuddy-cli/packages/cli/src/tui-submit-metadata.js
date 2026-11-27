export function withTuiMetadata(result, activeApp, mode) {
    return {
        kind: "started_turn",
        result: {
            ...result,
            locale: result.locale ?? activeApp.getLocale?.(),
            mode,
            model: result.model ?? activeApp.getModel?.(),
            theme: result.theme ?? activeApp.getTheme?.(),
            thoughtLevel: result.thoughtLevel ?? activeApp.getThoughtLevel?.(),
        },
    };
}
