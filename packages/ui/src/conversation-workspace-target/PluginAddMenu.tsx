import { ChevronDown, LoaderCircle, Plus, Sparkles } from "lucide-react";
import type { CreateTaskRequest } from "@/app-shell/types.js";
import { Button } from "@/components/ui/button.js";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu.js";
import { usePluginCreator } from "@/conversation-workspace-target/usePluginCreator.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";

export function PluginAddMenu({
  onCreateTask,
  onAddMarketplace,
  testId,
  variant,
  size,
}: {
  onCreateTask?: (request?: CreateTaskRequest) => void;
  onAddMarketplace: () => void;
  testId: string;
  variant?: Parameters<typeof Button>[0]["variant"];
  size?: Parameters<typeof Button>[0]["size"];
}) {
  const { intl } = useCCbuddyIntl();
  const creator = usePluginCreator(onCreateTask);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button type="button" variant={variant} size={size} data-testid={testId}>
          {creator.busy ? (
            <LoaderCircle className="size-3.5 animate-spin" aria-hidden="true" />
          ) : null}
          {intl.formatMessage({ id: "pluginCreator.add" })}
          <ChevronDown className="size-3.5" aria-hidden="true" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" data-testid="plugin-add-menu">
        <DropdownMenuItem
          data-testid="plugin-create-menu-item"
          disabled={creator.busy || !creator.available}
          onSelect={() => void creator.create()}
        >
          <Sparkles className="size-4" aria-hidden="true" />
          {intl.formatMessage({ id: "pluginCreator.create" })}
        </DropdownMenuItem>
        <DropdownMenuItem
          data-testid="plugin-store-add-source-menu-item"
          onSelect={onAddMarketplace}
        >
          <Plus className="size-4" aria-hidden="true" />
          {intl.formatMessage({ id: "pluginCreator.addMarketplace" })}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
