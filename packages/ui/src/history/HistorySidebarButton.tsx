import { CalendarDays, List } from "lucide-react";
import { Button } from "../components/ui/button.js";
import { cn } from "../components/lib/utils.js";
import { useCCbuddyIntl } from "../i18n/IntlProvider.js";

export function HistorySidebarButton({
  view,
  activeView,
  onOpen,
}: {
  view: "list" | "timeline";
  activeView: "list" | "timeline" | null;
  onOpen: (view: "list" | "timeline") => void;
}) {
  const { intl } = useCCbuddyIntl();
  const Icon = view === "timeline" ? CalendarDays : List;
  return (
    <Button
      type="button"
      variant="ghost"
      size="lg"
      data-icon="inline-start"
      data-testid={`history-${view}-sidebar-open`}
      aria-pressed={activeView === view}
      className={cn(
        "w-full justify-start gap-2 text-foreground hover:bg-surface-hover hover:text-foreground",
        activeView === view && "bg-selected text-foreground",
      )}
      onClick={() => onOpen(view)}
    >
      <Icon className="size-4" />
      {intl.formatMessage({
        id: view === "timeline" ? "workspace.openHistoryTimeline" : "workspace.openHistorySessions",
      })}
    </Button>
  );
}
