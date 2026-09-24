import type { UiLocale, SupportedLocale } from "@ccbuddy/contracts";
import { enUS } from "./locales/en-US.js";
import { zhCN } from "./locales/zh-CN.js";
import {
  DEFAULT_LOCALE,
  detectLocale,
  isSupportedLocale,
  isUiLocale,
  resolveLocale,
  SUPPORTED_LOCALES,
} from "./locale.js";
import type { CCbuddyCopy } from "./types.js";

export {
  DEFAULT_LOCALE,
  SUPPORTED_LOCALES,
  detectLocale,
  isSupportedLocale,
  isUiLocale,
  resolveLocale,
};
export type { LocaleDetectionInput } from "./locale.js";
export type { CliCopy, TuiCopy, UiLocale, SupportedLocale, CCbuddyCopy } from "./types.js";

const CATALOGS: Record<SupportedLocale, CCbuddyCopy> = {
  "en-US": enUS,
  "zh-CN": zhCN,
};

export function getCCbuddyCopy(locale?: UiLocale | string, detected?: string | null): CCbuddyCopy {
  return CATALOGS[resolveLocale(locale, detected)];
}
