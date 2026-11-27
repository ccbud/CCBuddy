import { detectLocale, resolveLocale } from "@ccbuddy/i18n";
export function detectCliLocale(env) {
    return detectLocale({
        env,
        intlLocale: resolveIntlLocale(),
    });
}
export function resolveDisplayLocale(locale, detectedLocale) {
    if (locale === undefined)
        return undefined;
    return resolveLocale(locale, detectedLocale);
}
function resolveIntlLocale() {
    try {
        return Intl.DateTimeFormat().resolvedOptions().locale;
    }
    catch {
        return undefined;
    }
}
