import { createLocalServices, getAppConfigDir } from "@ccbuddy/services/node";
import {
  materializeBundledCCbuddyBuiltinProviderConfig,
  readBundledCCbuddyBuiltinProviderConfig,
} from "./bundledCCbuddyBuiltinProviderConfig.js";
import { createHttpServer } from "./http.js";

async function main(): Promise<void> {
  const ccbuddyBuiltinProviderConfigFilePath = await materializeBundledCCbuddyBuiltinProviderConfig(
    {
      environmentConfigRoot: getAppConfigDir(),
      content: readBundledCCbuddyBuiltinProviderConfig(),
    },
  );
  const port = Number(process.env["PORT"]) || 3030;
  const host =
    process.env["CCBUDDY_SERVER_HOST"]?.trim() || process.env["HOST"]?.trim() || undefined;
  const staticRoot = process.env["CCBUDDY_WEB_STATIC_ROOT"]?.trim() || undefined;
  const authToken = process.env["CCBUDDY_SERVER_AUTH_TOKEN"]?.trim() || undefined;
  const services = createLocalServices({
    ccbuddyBuiltinProviderConfigFilePath,
    providerProvisioningTargetEnabled: Boolean(authToken),
  });

  createHttpServer(services, port, {
    ...(host ? { host } : {}),
    ...(staticRoot ? { staticRoot, spaFallback: true } : {}),
    ...(authToken ? { authToken, authRequired: true } : {}),
  });
}

void main().catch((error: unknown) => {
  console.error("[ccbuddy-server:http] startup failed", error);
  process.exitCode = 1;
});
