import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  IClientScenesService,
  IConversationShareService,
  IOAuthService,
  type IServiceAccessor,
} from "@ccbuddy/services";
import { createRemoteWorkspaceServiceCollection } from "./remoteWorkspaceServiceCollection.js";

test("remote workspace cannot reopen account APIs, OAuth, or sharing", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-remote-cloud-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  const previousFetch = globalThis.fetch;
  let fetchCalls = 0;
  process.env.CCBUDDY_DATA_BASE_DIR = root;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("unexpected network request");
  };
  try {
    const stub = {};
    const connectionServices = {
      fileService: stub,
      gitService: stub,
      gitCheckpointService: stub,
      systemService: stub,
      terminalService: stub,
      ccbuddyTaskService: stub,
      ccbuddyAgentService: {
        onDynamicSessionRuntimePreferencesRequest: () => () => {},
      },
      ccbuddySessionService: stub,
      fileWatcherService: stub,
      skillsService: stub,
      skillSyncService: stub,
      mcpSyncService: stub,
      pluginSyncService: stub,
      pluginsService: stub,
      pluginManagementService: stub,
      commandsService: stub,
      hooksService: stub,
      modelSelectionService: stub,
      providerSettingsService: stub,
    } as unknown as IServiceAccessor;
    const services = createRemoteWorkspaceServiceCollection({
      clientConfigService: stub as never,
      connectionServices,
      parentPort: null,
      createReportingRemoteCCbuddyTaskService: (service) => service,
      createRemotePromptAttachmentTaskService: (service) => service,
      createRemotePromptAttachmentSessionService: (service) => service,
      promptAttachmentTransferService: stub as never,
      runtimePreferencesBridge: { onError: () => {} },
    });

    const oauth = services.get(IOAuthService);
    assert.deepEqual(await oauth.getProviders(), []);
    await assert.rejects(oauth.startOAuth("zai"), /user-configured model services/);
    assert.deepEqual(await services.get(IClientScenesService).list(), {
      code: 0,
      msg: "",
      data: [],
    });
    await assert.rejects(
      services.get(IConversationShareService).getCapabilities(),
      /Conversation sharing is unavailable/,
    );
    assert.equal(fetchCalls, 0);
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    globalThis.fetch = previousFetch;
    await rm(root, { recursive: true, force: true });
  }
});
