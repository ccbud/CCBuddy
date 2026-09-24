import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { test } from "node:test";
import forge from "node-forge";
import {
  copyDataDirectory,
  getAppConfigDir,
  getConversationWorkspaceDir,
  getWorkspaceAppConfigDir,
  getCCbuddyDataRootDir,
  setDataBaseDir,
} from "../src/paths.ts";
import { loadWorkspaceFileSearchIgnoreRules } from "../src/file/workspaceFileIgnore.ts";
import { createSettingService } from "../src/setting/settingService.ts";
import { ensureAppCaCert } from "../src/runtime-tools/appCaCert.ts";

test("CCbuddy data paths never resolve to an existing CCbuddy home", async () => {
  const parent = await mkdtemp(join(tmpdir(), "ccbuddy-data-paths-"));
  const home = join(parent, "home");
  const destination = join(parent, "destination");
  try {
    await mkdir(join(home, ".ccbuddy", "v2"), { recursive: true });
    await writeFile(join(home, ".ccbuddy", "v2", "setting.json"), "ccbuddy sentinel\n");
    await mkdir(join(home, ".ccbuddy", "v2"), { recursive: true });
    await writeFile(join(home, ".ccbuddy", "v2", "session.db"), "ccbuddy session\n");
    setDataBaseDir(home);

    assert.equal(getCCbuddyDataRootDir(), join(home, ".ccbuddy"));
    assert.equal(getAppConfigDir(), join(home, ".ccbuddy", "v2"));
    assert.equal(getConversationWorkspaceDir(), join(home, ".ccbuddy", "workspace", "default"));
    const workspaceAppConfigDir = getWorkspaceAppConfigDir(join(home, "project"));
    assert.equal(dirname(workspaceAppConfigDir), join(home, ".ccbuddy", "workspaces"));
    assert.match(basename(workspaceAppConfigDir), /^[a-f0-9]{12}$/);
    assert.equal(
      getWorkspaceAppConfigDir(join(home, "project"), "remote-workspace"),
      getWorkspaceAppConfigDir(join(home, "other"), "remote-workspace"),
    );

    await copyDataDirectory(home, destination);
    assert.equal(
      await readFile(join(destination, ".ccbuddy", "v2", "session.db"), "utf8"),
      "ccbuddy session\n",
    );
    assert.equal(
      await readFile(join(home, ".ccbuddy", "v2", "setting.json"), "utf8"),
      "ccbuddy sentinel\n",
    );
    await assert.rejects(readFile(join(destination, ".ccbuddy", "v2", "setting.json"), "utf8"));
  } finally {
    setDataBaseDir(null);
    await rm(parent, { recursive: true, force: true });
  }
});

test("workspace search rules are stored under CCbuddy without changing the project", async () => {
  const parent = await mkdtemp(join(tmpdir(), "ccbuddy-workspace-paths-"));
  const project = join(parent, "project");
  const dataBase = join(parent, "data");
  try {
    await mkdir(project);
    await writeFile(join(project, ".gitignore"), "private/\n");
    setDataBaseDir(dataBase);

    const rules = await loadWorkspaceFileSearchIgnoreRules(project);
    assert.equal(rules.source, "created-from-gitignore");
    assert.match(
      await readFile(join(getWorkspaceAppConfigDir(project), ".ccbuddyignore"), "utf8"),
      /private\//,
    );
    await assert.rejects(readFile(join(project, ".ccbuddyignore"), "utf8"));
    await assert.rejects(readFile(join(project, ".ccbuddyignore"), "utf8"));
  } finally {
    setDataBaseDir(null);
    await rm(parent, { recursive: true, force: true });
  }
});

test("application network CA carries CCbuddy identity and leaves CCbuddy's CA untouched", async () => {
  const home = await mkdtemp(join(tmpdir(), "ccbuddy-network-ca-"));
  const ccbuddyCertPath = join(home, ".ccbuddy", "v2", "certs", "ccbuddy-network-ca.pem");
  try {
    await mkdir(dirname(ccbuddyCertPath), { recursive: true });
    await writeFile(ccbuddyCertPath, "ccbuddy sentinel\n");
    setDataBaseDir(home);

    const certPath = ensureAppCaCert();
    assert.equal(certPath, join(getAppConfigDir(), "certs", "ccbuddy-network-ca.pem"));
    const cert = forge.pki.certificateFromPem(await readFile(certPath, "utf8"));
    assert.equal(cert.subject.getField("CN")?.value, "CCbuddy Network CA");
    assert.equal(cert.subject.getField("O")?.value, "CCbuddy");
    assert.equal(cert.issuer.getField("CN")?.value, "CCbuddy Network CA");
    assert.ok(
      (await readFile(join(getAppConfigDir(), "certs", "ccbuddy-network-ca.key"), "utf8")).length >
        0,
    );
    assert.equal(ensureAppCaCert(), certPath);
    assert.equal(await readFile(ccbuddyCertPath, "utf8"), "ccbuddy sentinel\n");
  } finally {
    setDataBaseDir(null);
    await rm(home, { recursive: true, force: true });
  }
});

test("settings writes stay in CCbuddy's home and leave a CCbuddy sentinel untouched", async () => {
  const home = await mkdtemp(join(tmpdir(), "ccbuddy-settings-home-"));
  const previousHome = process.env.HOME;
  const previousDesktopHome = process.env.CCBUDDY_DESKTOP_HOME_DIR;
  try {
    process.env.HOME = home;
    process.env.CCBUDDY_DESKTOP_HOME_DIR = home;
    await mkdir(join(home, ".ccbuddy", "v2"), { recursive: true });
    await writeFile(join(home, ".ccbuddy", "v2", "setting.json"), "ccbuddy sentinel\n");

    await createSettingService().update({});

    assert.ok((await readFile(join(home, ".ccbuddy", "v2", "setting.json"), "utf8")).length > 0);
    assert.equal(
      await readFile(join(home, ".ccbuddy", "v2", "setting.json"), "utf8"),
      "ccbuddy sentinel\n",
    );
  } finally {
    if (previousHome === undefined) delete process.env.HOME;
    else process.env.HOME = previousHome;
    if (previousDesktopHome === undefined) delete process.env.CCBUDDY_DESKTOP_HOME_DIR;
    else process.env.CCBUDDY_DESKTOP_HOME_DIR = previousDesktopHome;
    await rm(home, { recursive: true, force: true });
  }
});
