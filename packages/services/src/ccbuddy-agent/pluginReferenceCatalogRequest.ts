import {
  ccbuddyProtocolMethods,
  ccbuddyPluginsReferenceCatalogResultSchema,
  type CCbuddyPluginsReferenceCatalogParams,
} from "@ccbuddy/shared";
import type { CCbuddyProtocolClient } from "#src/ccbuddy-agent/ccbuddyProtocolClient.js";

/** 旧协议严格校验响应；新展示字段走独立入口，只有 -32601 能证明旧 Agent 不支持。 */
export async function requestPluginReferenceCatalog(
  client: Pick<CCbuddyProtocolClient, "request">,
  params: CCbuddyPluginsReferenceCatalogParams,
) {
  try {
    return await client.request(
      ccbuddyProtocolMethods.pluginsReferenceCatalogWithCategory,
      params,
      ccbuddyPluginsReferenceCatalogResultSchema,
    );
  } catch (error) {
    if (!(typeof error === "object" && error !== null && "code" in error && error.code === -32601))
      throw error;
    return client.request(
      ccbuddyProtocolMethods.pluginsReferenceCatalog,
      params,
      ccbuddyPluginsReferenceCatalogResultSchema,
    );
  }
}
