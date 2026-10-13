// @vitest-environment jsdom
import { act, renderHook } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import type { WorkspaceMainView } from "./types.js";
import { useWorkspaceMainViewSettingsExit } from "./useWorkspaceMainViewSettingsExit.js";
import { useHistoryMainViewNavigation } from "./useHistoryMainViewNavigation.js";

describe("native history navigation", () => {
  it("returns from Settings to the requested history route, including the same route", () => {
    let listener: ((view: "list" | "timeline") => void) | undefined;
    const dispose = vi.fn();
    const platform = {
      onOpenHistoryViewRequested: (next: NonNullable<typeof listener>) => {
        listener = next;
        return dispose;
      },
    };
    const { result, unmount } = renderHook(() => {
      const [visible, setVisible] = useState(false);
      const [view, setView] = useState<WorkspaceMainView>("history-timeline");
      const { preserveNextSettingsExit } = useWorkspaceMainViewSettingsExit({
        isWorkspaceVisible: visible,
        workspaceMainView: view,
        onExitSettings: () => setView("chat"),
      });
      useHistoryMainViewNavigation({
        platform,
        preserveNextSettingsExit,
        runVisibleWorkspaceCommand: (command) => {
          setVisible(true);
          command();
        },
        onWorkspaceMainViewChange: setView,
      });
      return { visible, view, setVisible };
    });

    act(() => listener?.("timeline"));
    expect(result.current).toMatchObject({ visible: true, view: "history-timeline" });
    act(() => result.current.setVisible(false));
    act(() => listener?.("list"));
    expect(result.current).toMatchObject({ visible: true, view: "history-list" });
    unmount();
    expect(dispose).toHaveBeenCalled();
  });

  it("consumes a menu command replayed when the renderer subscribes", () => {
    const navigate = vi.fn();
    const preserve = vi.fn();
    renderHook(() =>
      useHistoryMainViewNavigation({
        platform: {
          onOpenHistoryViewRequested: (listener) => {
            listener("list");
            return () => {};
          },
        },
        preserveNextSettingsExit: preserve,
        runVisibleWorkspaceCommand: (command) => command(),
        onWorkspaceMainViewChange: navigate,
      }),
    );
    expect(preserve).toHaveBeenCalledOnce();
    expect(navigate).toHaveBeenCalledWith("history-list");
  });
});
