import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { DEFAULT_WORKSPACE, waitForWorkspaceApp } from "#e2e/helpers/desktop-app";
import { isIsolatedE2EHomeDir } from "#e2e/helpers/e2e-runtime-paths";
import { restartIntoWorkspacePreservingProfile } from "#e2e/helpers/model-provider-restart-runtime";
import { seedProviderReadinessHistoryFixture } from "#e2e/helpers/provider-readiness-history-fixture";

const marker = "E2E_HISTORY_TITLE";
const bodyMarker = "E2E_HISTORY_BODY";
const inputSelector = '[role="dialog"] [cmdk-input]';
const rowSelector = '[role="dialog"] [cmdk-item][data-value^="task-result:"]';
const cases = ["active", "pinned", "archived", "unclassified", "deleted", "cli-deleted", "foreign"];
const visibleCases = cases.slice(0, 4);
let closedWorkspace: string;
let home: string;

describe("Command Center Host 历史搜索", () => {
  afterEach(async () => {
    const snapshot = await browser.execute(() => ({
      text: document.body.innerText.slice(0, 12000),
      rows: Array.from(document.querySelectorAll('[role="dialog"] [cmdk-item]')).map((row) => ({
        text: row.textContent,
        value: row.getAttribute("data-value"),
      })),
    }));
    await writeFile(
      join(process.env.CCBUDDY_E2E_ARTIFACT_DIR!, "history-search-state.json"),
      JSON.stringify(snapshot, null, 2),
    );
  });
  before(async () => {
    await waitForWorkspaceApp(DEFAULT_WORKSPACE, 45_000);
    home = process.env.CCBUDDY_E2E_HOME_DIR ?? "";
    // 旧 basename 守卫误拒 runner 默认的 .e2e-home；复用统一守卫，仍禁止写普通 HOME。
    if (!isIsolatedE2EHomeDir(home)) throw new Error("需要隔离 E2E HOME");
    closedWorkspace = join(home, "ClosedHistoryWorkspace");
    await mkdir(closedWorkspace, { recursive: true });
    await restartIntoWorkspacePreservingProfile(DEFAULT_WORKSPACE, {
      afterElectronProcessExit: async () => {
        for (const name of cases) {
          await seedProviderReadinessHistoryFixture({
            cliEntryPoint: resolve("../../apps/ccbuddy-cli/packages/cli/dist/ccbuddy.cjs"),
            e2eHomeDir: home,
            workspacePath: closedWorkspace,
            history: {
              sessionId: `session_e2e_history_${name}`,
              title: `${marker}_${name}`,
              userText: `${bodyMarker}_${name}`,
              assistantText: `Persisted history ${name}`,
              modelId: "missing-model",
              runtimeProviderId: "missing-provider",
              taskProviderId: "glm",
              assistantInputTokens: 0,
              assistantOutputTokens: 0,
            },
          });
        }
        // node:sqlite 只提供同步接口；夹具在 Host 退出后写入，避免与迁移/索引写入竞争。
        const db = new DatabaseSync(join(home, ".ccbuddy/v2/tasks-index.sqlite"));
        try {
          const stamp = Date.now() - 36 * 24 * 60 * 60 * 1000;
          db.prepare(`UPDATE tasks SET host_id='local', root_path=workspace_path,
            project_id=NULL, cli_title=title, cli_title_source='custom', cli_created_at=?,
            cli_updated_at=?, created_at=?, updated_at=?, cli_deleted=0, handoff_pending=8
            WHERE task_id LIKE 'session_e2e_history_%'`).run(stamp, stamp, stamp, stamp);
          db.exec(`UPDATE tasks SET pinned=1 WHERE task_id='session_e2e_history_pinned';
            UPDATE tasks SET archived=1 WHERE task_id='session_e2e_history_archived';
            UPDATE tasks SET deleted=1 WHERE task_id='session_e2e_history_deleted';
            UPDATE tasks SET cli_deleted=1 WHERE task_id='session_e2e_history_cli-deleted';
            UPDATE tasks SET host_id='server:other-device' WHERE task_id='session_e2e_history_foreign'`);
          db.prepare(`INSERT INTO projects(project_id,host_id,name,position,created_at,updated_at)
            VALUES('e2e-history-project','local','E2E_HISTORY_PROJECT',100,?,?)`).run(stamp, stamp);
          db.prepare(
            `INSERT INTO project_roots(project_id,root_path,position) VALUES('e2e-history-project',?,0)`,
          ).run(closedWorkspace);
          db.exec(`UPDATE tasks SET project_id='e2e-history-project' WHERE task_id IN
            ('session_e2e_history_active','session_e2e_history_pinned','session_e2e_history_archived')`);
        } finally {
          db.close();
        }
        const settingsPath = join(home, ".ccbuddy/v2/setting.json");
        const settings = JSON.parse(await readFile(settingsPath, "utf8"));
        await writeFile(
          settingsPath,
          JSON.stringify({ ...settings, taskAutoArchiveEnabled: false }),
        );
      },
    });
  });

  it("CC-HISTORY-01：未打开目录的一个月前标题/正文、置顶、归档及 Host 隔离", async () => {
    const tabs = await browser.execute(() => {
      const store = (
        window as typeof window & {
          __ccbuddyTabStoreE2E?: { getState(): { tabs: Array<{ workspacePath?: string }> } };
        }
      ).__ccbuddyTabStoreE2E;
      if (!store) throw new Error("缺少 tab store 测试入口");
      return store.getState().tabs.map((tab) => tab.workspacePath);
    });
    expect(tabs).not.toContain(closedWorkspace);
    await openSearch();
    await searchAndExpect(marker, visibleCases);
    for (const name of visibleCases) await searchAndExpect(`${bodyMarker}_${name}`, [name]);
    await browser.saveScreenshot(
      join(process.env.CCBUDDY_E2E_ARTIFACT_DIR!, "history-cold-search.png"),
    );
    await browser.keys("Escape");
  });

  it("CC-HISTORY-02：点击未打开目录的归档结果并再次搜索", async () => {
    await openSearch();
    await searchAndExpect(`${marker}_archived`, ["archived"]);
    await $(rowSelector).click();
    await browser.waitUntil(
      () =>
        browser.execute((text) => document.body.innerText.includes(text), `${bodyMarker}_archived`),
      { timeout: 45_000, timeoutMsg: "应打开归档任务的真实持久化正文" },
    );
    await openSearch();
    await searchAndExpect(marker, visibleCases);
    await browser.keys("Escape");
    const db = new DatabaseSync(join(home, ".ccbuddy/v2/tasks-index.sqlite"), { readOnly: true });
    try {
      expect(
        db.prepare("SELECT archived FROM tasks WHERE task_id='session_e2e_history_archived'").get(),
      ).toEqual({ archived: 1 });
    } finally {
      db.close();
    }
  });
});

async function openSearch() {
  await $('[data-testid="sidebar-search-open"]').click();
  await $(inputSelector).waitForDisplayed();
  await $('[role="dialog"]')
    .$('.//button[@role="tab" and (normalize-space(.)="任务" or normalize-space(.)="Tasks")]')
    .click();
}

async function searchAndExpect(query: string, names: string[]) {
  await $(inputSelector).setValue(query);
  await browser.waitUntil(
    async () => {
      const texts = await $$(rowSelector).map((row) => row.getText());
      return (
        texts.length === names.length &&
        names.every((name) => texts.some((text) => text.includes(`${marker}_${name}`)))
      );
    },
    { timeout: 10_000, timeoutMsg: `历史搜索 ${query} 应返回 ${names.join(",")}` },
  );
}
