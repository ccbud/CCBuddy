import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { applyEmbeddedBrowserPermissionPolicy } from "../src/main/embeddedBrowserPermissionPolicy.ts";
import { createEmbeddedBrowserSitePermissionStore } from "../src/main/embeddedBrowserSitePermissionStore.ts";
import { resetEmbeddedBrowserSitePermissionsForTest } from "../src/main/embeddedBrowserSitePermissions.ts";

afterEach(resetEmbeddedBrowserSitePermissionsForTest);

function permissionSession() {
  const session = new EventEmitter();
  for (const kind of ["Request", "Check", "Device"]) {
    session[`setPermission${kind}Handler`] = (handler) => {
      session[kind] = handler;
    };
  }
  session.setDevicePermissionHandler = (handler) => {
    session.Device = handler;
  };
  session.setDisplayMediaRequestHandler = (handler) => {
    session.Display = handler;
  };
  return session;
}

test("main loads saved browser permissions and installs the decision handlers before guest creation", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-permission-assembly-"));
  try {
    const path = join(root, "embedded-browser-site-permissions.json");
    const origin = "https://example.invalid";
    await writeFile(path, JSON.stringify({ [origin]: { media: "deny" } }));
    const source = await readFile(new URL("../src/main/index.ts", import.meta.url), "utf8");
    const tree = ts.createSourceFile("index.ts", source, ts.ScriptTarget.Latest, true);
    let policyCall;
    function visit(node) {
      if (
        ts.isCallExpression(node) &&
        node.expression.getText(tree) === "applyEmbeddedBrowserPermissionPolicy"
      ) {
        policyCall = node;
      }
      ts.forEachChild(node, visit);
    }
    visit(tree);
    assert.ok(policyCall, "main must install the permission policy before creating guests");
    const session = permissionSession();
    let prompts = 0;
    let displayRequest;
    const writes = [];
    const context = {
      applyEmbeddedBrowserPermissionPolicy,
      createEmbeddedBrowserSitePermissionStore: (path) => {
        const store = createEmbeddedBrowserSitePermissionStore(path);
        return {
          ...store,
          persist(record) {
            const write = store.persist(record);
            writes.push(write);
            return write;
          },
        };
      },
      session: { fromPartition: () => session },
      EMBEDDED_BROWSER_PARTITION: "persist:ccbuddy-browser",
      embeddedBrowserPermissionUiBridge: {
        promptPermission: async () => {
          prompts++;
          return "allow-always";
        },
        devicePicker: () => ({ result: Promise.resolve(null), updateDevices() {} }),
        onDisplayMediaRequest: (input, callback) => {
          displayRequest = input;
          callback({});
        },
      },
      logger: { info() {}, warn() {} },
      app: { getPath: () => root },
      join,
    };
    const script = ts.transpileModule(`const result = ${policyCall.getText(tree)};`, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    await runInNewContext(`(() => { ${script}\nreturn result; })()`, context);
    assert.equal(session.Check(null, "media", origin), false);
    assert.equal(typeof session.Display, "function");
    const requestingFrame = { url: origin };
    session.Display({ frame: requestingFrame }, () => {});
    assert.equal(displayRequest.frame, requestingFrame);
    assert.equal(session.listenerCount("select-usb-device"), 1);
    const denied = await new Promise((resolve) =>
      session.Request({ id: 20, hostWebContents: { id: 7 } }, "media", resolve, {
        requestingUrl: origin,
      }),
    );
    assert.equal(denied, false);
    assert.equal(prompts, 0, "saved denial must not be replaced by another prompt");

    const allowed = await new Promise((resolve) =>
      session.Request({ id: 20, hostWebContents: { id: 7 } }, "geolocation", resolve, {
        requestingUrl: origin,
      }),
    );
    assert.equal(allowed, true);
    assert.equal(prompts, 1);
    await Promise.all(writes);
    assert.equal(
      (await createEmbeddedBrowserSitePermissionStore(path).load())[origin].geolocation,
      "allow",
    );

    resetEmbeddedBrowserSitePermissionsForTest();
    const reloaded = permissionSession();
    await applyEmbeddedBrowserPermissionPolicy(reloaded, {
      logger: { info() {}, warn() {} },
      store: createEmbeddedBrowserSitePermissionStore(path),
    });
    assert.equal(reloaded.Check(null, "media", origin), false);
    assert.equal(reloaded.Check(null, "geolocation", origin), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("device selection isolates native frames and coalesces discoveries only within one request", async () => {
  const session = permissionSession();
  const choices = [];
  const callbacks = [];
  await applyEmbeddedBrowserPermissionPolicy(session, {
    logger: { info() {}, warn() {} },
    devicePicker(input) {
      const updates = [];
      let resolve;
      const result = new Promise((done) => {
        resolve = done;
      });
      choices.push({ input, updates, resolve });
      return { result, updateDevices: (devices) => updates.push(devices) };
    },
  });
  const origin = "https://example.invalid";
  const firstFrame = { url: origin, processId: 101, routingId: 1 };
  const secondFrame = { url: origin, processId: 102, routingId: 1 };
  function choose(frame, deviceId) {
    return new Promise((resolve) => {
      session.emit(
        "select-usb-device",
        { preventDefault() {} },
        {
          frame,
          deviceList: [{ deviceId, deviceName: deviceId }],
        },
        (value) => {
          callbacks.push(value);
          resolve();
        },
      );
    });
  }
  const firstCompleted = choose(firstFrame, "device-1");
  const secondCompleted = choose(secondFrame, "device-2");
  choose(firstFrame, "device-3");
  assert.equal(choices.length, 2, "different native frames must not share a chooser or callback");
  assert.equal(choices[0].input.frame, firstFrame);
  assert.equal(choices[1].input.frame, secondFrame);
  assert.equal(choices[0].updates.length, 1);
  assert.equal(choices[1].updates.length, 0);
  choices[0].resolve({ deviceId: "device-1" });
  choices[1].resolve({ deviceId: "device-2" });
  await Promise.all([firstCompleted, secondCompleted]);
  assert.deepEqual(callbacks, ["device-1", "device-2"]);
});
