// @vitest-environment jsdom
import { cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { CCbuddyIntlProvider } from "../i18n/IntlProvider.js";
import { HistorySidebarButton } from "./HistorySidebarButton.js";

afterEach(cleanup);

it.each(["zh-CN", "en-US"] as const)(
  "routes both history commands with localized labels in %s",
  (locale) => {
    const open = vi.fn();
    const { getAllByRole, getByTestId } = render(
      <CCbuddyIntlProvider initialLocale={locale}>
        <HistorySidebarButton view="timeline" activeView="timeline" onOpen={open} />
        <HistorySidebarButton view="list" activeView="timeline" onOpen={open} />
      </CCbuddyIntlProvider>,
    );
    expect(
      getAllByRole("button").every((button) => !button.textContent?.includes("workspace.")),
    ).toBe(true);
    const calendar = getByTestId("history-timeline-sidebar-open");
    const sessions = getByTestId("history-list-sidebar-open");
    expect(calendar.getAttribute("aria-pressed")).toBe("true");
    expect(sessions.getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(calendar);
    fireEvent.click(sessions);
    expect(open.mock.calls).toEqual([["timeline"], ["list"]]);
  },
);
