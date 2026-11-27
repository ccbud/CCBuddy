import { Blocks, CalendarClock } from "lucide-react";
import { memo } from "react";
import { TID_AUTOMATIONS_OPEN } from "@ccbuddy/shared/test-ids";
import type { ProjectSidebarProps } from "@/project-sidebar/contract.js";
import { Button } from "@/components/ui/button.js";
import { NewTaskButtonGroup } from "@/NewTaskButtonGroup.js";
import { HistorySidebarButton } from "@/history/HistorySidebarButton.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";
import { NavPrimarySlot } from "@/extension-slots/index.js";

/** 顶部导航只展示 Shell 的选中状态，路由仍由 Shell 唯一持有。 */
// 展开偏好会更新侧栏父组件；导航按原 props 和稳定命令隔离，避免无关菜单跟随渲染。
export const ProjectSidebarNavigation = memo(function ProjectSidebarNavigation({
  props,
  onCreate,
}: {
  props: Pick<
    ProjectSidebarProps,
    | "onOpenAutomations"
    | "automationsActive"
    | "onOpenPluginStore"
    | "pluginStoreActive"
    | "navPrimarySlot"
    | "workspacePath"
    | "workspaceIdentity"
    | "workspaceRemoteSessionId"
    | "onOpenHistoryView"
    | "historyViewActive"
  >;
  onCreate(): void;
}) {
  const { intl } = useCCbuddyIntl();
  return (
    <div data-testid="sidebar-primary-navigation" className="flex flex-col gap-1 px-2 py-3">
      {props.onOpenHistoryView ? (
        <HistorySidebarButton
          view="timeline"
          activeView={props.historyViewActive ?? null}
          onOpen={props.onOpenHistoryView}
        />
      ) : null}
      <NewTaskButtonGroup onCreateTask={onCreate} />
      {props.onOpenAutomations ? (
        <Button
          variant="ghost"
          size="lg"
          className={`w-full justify-start gap-2 ${props.automationsActive ? "bg-selected text-foreground" : ""}`}
          aria-pressed={props.automationsActive ?? false}
          data-testid={TID_AUTOMATIONS_OPEN}
          // 点击事件不能进入业务导航的可选 automationId 参数。
          onClick={() => props.onOpenAutomations?.()}
        >
          <CalendarClock className="size-4" />
          {intl.formatMessage({ id: "workspace.openScheduledSettings" })}
        </Button>
      ) : null}
      <Button
        variant="ghost"
        size="lg"
        className={`w-full justify-start gap-2 ${props.pluginStoreActive ? "bg-selected text-foreground" : ""}`}
        aria-pressed={props.pluginStoreActive ?? false}
        data-testid="plugin-store-sidebar-open"
        onClick={() => props.onOpenPluginStore?.()}
      >
        <Blocks className="size-4" />
        {intl.formatMessage({ id: "workspace.openPluginsSettings" })}
      </Button>
      {/* 扩展导航条目（nav.primary）；逻辑都在 extension-slots。 */}
      {props.navPrimarySlot ? (
        <NavPrimarySlot
          workspacePath={props.workspacePath}
          {...(props.workspaceIdentity ? { workspaceIdentity: props.workspaceIdentity } : {})}
          {...(props.workspaceRemoteSessionId
            ? { workspaceRemoteSessionId: props.workspaceRemoteSessionId }
            : {})}
          {...props.navPrimarySlot}
        />
      ) : null}
    </div>
  );
});
