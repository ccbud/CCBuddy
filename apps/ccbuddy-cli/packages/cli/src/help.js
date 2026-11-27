import { getCCbuddyCopy } from "@ccbuddy/i18n";
export function formatCliHelp(version, locale, detectedLocale) {
    return getCCbuddyCopy(locale, detectedLocale).cli.help(version);
}
