import {
  BUILTIN_CCBUDDY_SLASH_COMMAND_HELP_ENTRIES,
  type BuiltinCCbuddySlashCommandHelpEntry,
} from "@ccbuddy/shared";

export type SlashCommandHelpEntry = BuiltinCCbuddySlashCommandHelpEntry;
export const SLASH_COMMAND_HELP_ENTRIES = BUILTIN_CCBUDDY_SLASH_COMMAND_HELP_ENTRIES.filter(
  (entry) => entry.name !== "login" && entry.name !== "logout",
);
