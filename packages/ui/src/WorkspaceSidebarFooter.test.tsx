// @vitest-environment jsdom
import { fireEvent, render } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { CCbuddyIntlProvider } from "./i18n/IntlProvider.js";
import { WorkspaceSidebarFooter } from "./WorkspaceSidebarFooter.js";
import { TooltipProvider } from "./components/ui/tooltip.js";

vi.mock("@/hooks/usePlatform.js", () => ({ usePlatform: () => ({}) }));
vi.mock("@/shortcuts/useShortcutBindings.js", () => ({ useShortcutCommandLabel: () => "" }));
vi.mock("@/store/StoreProvider.js", () => ({
  useCCbuddyStore: (select: (state: unknown) => unknown) =>
    select({ interfaceMode: "developer", setInterfaceMode: () => {} }),
}));
vi.mock("@/WorkspaceSidebarFooterUsageSummary.js", () => ({
  useWorkspaceSidebarFooterUsageSummaryState: () => {
    throw new Error("BYOK footer must not mount account entitlement hooks");
  },
}));

it("keeps the profile menu usable without account hooks, login, or purchase controls", () => {
  const login = vi.fn();
  const upgrade = vi.fn();
  const { getByTestId, getByRole, queryByTestId } = render(
    <CCbuddyIntlProvider initialLocale="en-US">
      <TooltipProvider>
        <WorkspaceSidebarFooter
          theme="zai-light"
          localeMenuValue="en-US"
          onLocaleChange={() => {}}
          onThemeChange={() => {}}
          onLogin={login}
          onUpgradeClick={upgrade}
        />
      </TooltipProvider>
    </CCbuddyIntlProvider>,
  );
  const profile = getByTestId("login-trigger");
  expect(profile.textContent).toContain("CCbuddy");
  fireEvent.keyDown(profile, { key: "Enter" });
  expect(getByRole("menu").getAttribute("data-state")).toBe("open");
  expect(queryByTestId("login-menu-item")).toBeNull();
  expect(queryByTestId("sidebar-coding-plan-upgrade-button")).toBeNull();
  expect(login).not.toHaveBeenCalled();
  expect(upgrade).not.toHaveBeenCalled();
});
