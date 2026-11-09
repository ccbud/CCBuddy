import {
  appToolSearchModeSchema,
  testId,
  TID_SETTINGS_TOOL_SEARCH_SELECT,
  TID_SETTINGS_TOOL_SEARCH_OPTION,
  type AppToolSearchMode,
} from "@ccbuddy/shared";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select.js";
import { SettingsRow } from "@/settings/SettingsPageParts.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";

export function ToolSearchModeSetting({
  value,
  onChange,
}: {
  value: AppToolSearchMode;
  onChange: (mode: AppToolSearchMode) => Promise<void>;
}) {
  const { intl } = useCCbuddyIntl();
  return (
    <SettingsRow
      label={intl.formatMessage({ id: "settings.toolSearch" })}
      description={intl.formatMessage({ id: "settings.toolSearchDescription" })}
      control={
        <Select
          value={value}
          onValueChange={(mode) => {
            void onChange(appToolSearchModeSchema.parse(mode));
          }}
        >
          <SelectTrigger
            size="lg"
            className="w-[260px] min-w-0 justify-between"
            data-testid={TID_SETTINGS_TOOL_SEARCH_SELECT}
          >
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {appToolSearchModeSchema.options.map((mode) => (
              <SelectItem
                key={mode}
                value={mode}
                data-testid={testId(TID_SETTINGS_TOOL_SEARCH_OPTION, mode)}
              >
                {intl.formatMessage({ id: `settings.toolSearch.${mode}` })}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      }
    />
  );
}
