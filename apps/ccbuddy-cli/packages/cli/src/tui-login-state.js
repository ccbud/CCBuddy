import { getCCbuddyCopy } from "@ccbuddy/i18n";
export function loginRequiredResponse(locale) {
    const copy = getCCbuddyCopy(locale).tui.loginRequired;
    return [copy.message, copy.help].join("\n");
}
/** Registry already applies provider/account availability, including personal providers. */
export function createTuiModelAvailabilityChecker(getApp) {
    return async () => {
        const app = await getApp();
        return ((await app.listModels?.()) ?? []).some((model) => !model.disabledReason);
    };
}
