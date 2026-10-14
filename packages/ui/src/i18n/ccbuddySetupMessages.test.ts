import { expect, it } from "vitest";
import en from "./locales/en-US.js";
import zh from "./locales/zh-CN.js";

it.each([en, zh])(
  "has history navigation and BYOK setup copy in every shipped locale",
  (messages) => {
    for (const id of [
      "workspace.openHistoryTimeline",
      "workspace.openHistorySessions",
      "settings.modelProvider.emptyDescription",
    ]) {
      expect(messages[id]).toBeTruthy();
      expect(messages[id]).not.toBe(id);
    }
    expect(messages["chat.error.noAvailableModel"]).not.toMatch(/upgrade|升级/i);
  },
);
