import { BUILTIN_CCBUDDY_SLASH_COMMAND_HELP_ENTRIES, } from "@ccbuddy/shared";
export const SLASH_COMMAND_HELP_ENTRIES = BUILTIN_CCBUDDY_SLASH_COMMAND_HELP_ENTRIES.filter((entry) => entry.name !== "login" && entry.name !== "logout");
