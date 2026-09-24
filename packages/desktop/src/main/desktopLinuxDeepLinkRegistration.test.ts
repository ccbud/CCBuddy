import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { registerLinuxDeepLinkProtocol } from "./desktopLinuxDeepLinkRegistration.js";

test("CCbuddy Linux registration preserves CCbuddy desktop entry and icon", async (t) => {
  const homeDir = await mkdtemp(join(tmpdir(), "ccbuddy-linux-registration-"));
  t.after(async () => rm(homeDir, { recursive: true, force: true }));
  const dataDir = join(homeDir, ".local", "share");
  const ccbuddyEntry = join(dataDir, "applications", "ccbuddy.desktop");
  const ccbuddyIcon = join(dataDir, "icons", "hicolor", "512x512", "apps", "ccbuddy.png");
  const iconSource = join(homeDir, "source.png");

  await mkdir(dirname(ccbuddyEntry), { recursive: true });
  await mkdir(dirname(ccbuddyIcon), { recursive: true });
  await writeFile(ccbuddyEntry, "Comment=CCbuddy Desktop App\nExec=ccbuddy\n");
  await writeFile(ccbuddyIcon, "ccbuddy-icon");
  await writeFile(iconSource, "ccbuddy-icon");

  const commands: Array<{ command: string; args: string[] }> = [];
  registerLinuxDeepLinkProtocol({
    executablePath: join(homeDir, "CCbuddy.AppImage"),
    homeDir,
    iconSourcePath: iconSource,
    env: { APPIMAGE: join(homeDir, "CCbuddy.AppImage"), XDG_DATA_HOME: dataDir },
    logger: { info: () => {}, warn: () => {} },
    runCommand: (command, args) => {
      commands.push({ command, args });
      return { status: 0 };
    },
    systemApplicationDirs: [],
  });

  assert.equal(await readFile(ccbuddyIcon, "utf8"), "ccbuddy-icon");
  const entry = await readFile(ccbuddyEntry, "utf8");
  assert.match(entry, /Name=CCbuddy/);
  assert.match(entry, /Comment=CCbuddy Desktop App/);
  assert.match(entry, /Icon=ccbuddy/);
  assert.ok(
    commands.some(
      ({ command, args }) =>
        command === "xdg-mime" &&
        args.join(" ") === "default ccbuddy.desktop x-scheme-handler/ccbuddy",
    ),
  );
});
