import assert from "node:assert/strict";
import test from "node:test";
import {
  IClientScenesService,
  IConversationShareService,
  IOAuthService,
  type IServiceAccessor,
} from "@ccbuddy/services";
import type { OAuthProviderId } from "@ccbuddy/shared";
import {
  REMOTE_WORKSPACE_RPC_REGISTRATIONS,
  createServerRemoteWorkspaceServiceCollection,
} from "./remoteWorkspaceServiceCollection.js";

// 远程工作区集合只做 RPC 转接：账号类接口由 services 组合根的封闭实现提供
// （见 packages/services/test/byok-cloud-boundary.test.ts）。这里守住桌面端这一层：
// 集合不得另起 OAuth / 场景客户端，server 目标的分享保持关闭，整个过程不发起网络请求。
test("remote workspace collection only forwards closed account APIs and keeps server sharing closed", async () => {
  const previousFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error("unexpected network request");
  };
  try {
    const oauthService = {
      getProviders: async () => [],
      startOAuth: async () => {
        throw new Error("user-configured model services");
      },
    };
    const clientScenesService = {
      list: async () => ({ code: 0, msg: "", data: [] as never[] }),
    };
    const connectionServices = Object.fromEntries(
      REMOTE_WORKSPACE_RPC_REGISTRATIONS.map(([key]) => [
        key,
        key === "oauthService"
          ? oauthService
          : key === "clientScenesService"
            ? clientScenesService
            : {},
      ]),
    ) as unknown as IServiceAccessor;

    const services = createServerRemoteWorkspaceServiceCollection({
      clientConfigService: {} as never,
      connectionServices,
      targetKind: "server",
    });

    assert.equal(services.get(IOAuthService), oauthService);
    assert.deepEqual(await services.get(IOAuthService).getProviders(), []);
    await assert.rejects(
      services.get(IOAuthService).startOAuth("zai" as OAuthProviderId),
      /user-configured model services/,
    );
    assert.equal(services.get(IClientScenesService), clientScenesService);
    assert.deepEqual(await services.get(IClientScenesService).list(), {
      code: 0,
      msg: "",
      data: [],
    });
    assert.notEqual(
      services.get(IConversationShareService),
      connectionServices.conversationShareService,
    );
    await assert.rejects(
      services.get(IConversationShareService).getCapabilities(),
      /Conversation sharing is not available/,
    );
    assert.equal(fetchCalls, 0);
  } finally {
    globalThis.fetch = previousFetch;
  }
});
