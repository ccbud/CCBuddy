import { getCCbuddyCopy, type SupportedLocale, type UiLocale } from "@ccbuddy/i18n";

export function formatCliHelp(
  version: string,
  locale?: UiLocale,
  detectedLocale?: SupportedLocale,
): string {
  return getCCbuddyCopy(locale, detectedLocale).cli.help(version);
}
