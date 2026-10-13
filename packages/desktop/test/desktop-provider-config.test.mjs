import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import { mock, test } from "node:test";
import { fileURLToPath } from "node:url";

mock.module("@ccbuddy/shared", { namedExports: { CCBUDDY_ENV: "test" } });
mock.module("electron", { namedExports: { app: { isPackaged: false } } });
const { resolveCCbuddyBuiltinProviderConfigFilePath } =
  await import("../src/main/desktopProviderConfig.ts");
const desktop = fileURLToPath(new URL("..", import.meta.url));

test("development Main injects the existing local BYOK template even in test environment", async () => {
  const path = resolveCCbuddyBuiltinProviderConfigFilePath({
    isPackaged: false,
    appPath: desktop,
    env: {},
    resourcesPath: "/unused",
  });
  await access(path);
  assert.equal(
    path,
    fileURLToPath(new URL("../../../config/provider/ccbuddy-builtin.json", import.meta.url)),
  );
});

test("installed Main uses the filename staged by the local provider build contract", () => {
  assert.equal(
    resolveCCbuddyBuiltinProviderConfigFilePath({
      isPackaged: true,
      resourcesPath: "/package/resources",
      env: {},
    }),
    "/package/resources/config/provider/ccbuddy-builtin.json",
  );
});
