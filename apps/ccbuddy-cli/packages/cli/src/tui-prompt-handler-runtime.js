import { loadBootstrapModule } from "./bootstrap-loader.js";
import { loadCliDotenv } from "./env.js";
import { resolveResumeSession } from "./resume.js";
export const createTuiProcessRuntimeState = () => ({
    providerEndpointRoutingPort: undefined,
    providerRegistryRuntimePromise: undefined,
    shutdownTelemetry: undefined,
});
// 返回值类型交给推断：原地 createApp 里这几个都是推断出来的局部变量，手写接口反而会把
// 品牌类型（SessionId）和 createCCbuddyApp 的联合签名收窄错。
export async function prepareTuiAppRuntime(deps, version, request, state) {
    const env = deps.env ?? process.env;
    const workingDirectory = (deps.cwd ?? process.cwd)();
    const dotenvResult = (deps.loadDotenv ?? loadCliDotenv)({
        cwd: workingDirectory,
        env,
    });
    if (dotenvResult.error) {
        throw new Error(`Failed to load environment file: ${dotenvResult.path}`, {
            cause: dotenvResult.error,
        });
    }
    const sessionId = await resolveResumeSession(request, workingDirectory, env, deps);
    const bootstrapModule = deps.createCCbuddyApp ? undefined : await loadBootstrapModule();
    const createAppFactory = deps.createCCbuddyApp ?? bootstrapModule?.createCCbuddyApp;
    if (!createAppFactory)
        throw new Error("CCbuddy app factory is unavailable.");
    const prepareTelemetry = deps.prepareCCbuddyTelemetryEnv ?? bootstrapModule?.prepareCCbuddyTelemetryEnv;
    if (prepareTelemetry) {
        state.shutdownTelemetry =
            deps.shutdownCCbuddyTelemetry ?? bootstrapModule?.shutdownCCbuddyTelemetry;
    }
    const appEnv = prepareTelemetry
        ? await prepareTelemetry(env, {
            cliVersion: version,
            productVersion: env.CCBUDDY_APP_VERSION,
        })
        : env;
    const startProviderRegistryRuntime = deps.startProcessProviderRegistryRuntime ??
        bootstrapModule?.startProcessProviderRegistryRuntime;
    if (!startProviderRegistryRuntime) {
        throw new Error("Provider Registry runtime is unavailable.");
    }
    state.providerRegistryRuntimePromise ??= startProviderRegistryRuntime(appEnv);
    const providerRegistryRuntime = await state.providerRegistryRuntimePromise;
    const configuredDefaultModelSelection = providerRegistryRuntime?.modelSelectionConfigRepository
        ? await providerRegistryRuntime.modelSelectionConfigRepository.read()
        : providerRegistryRuntime?.configuredDefaultModelSelection;
    const createProviderEndpointRoutingPort = deps.createProviderEndpointRoutingPort ??
        bootstrapModule?.createDefaultProviderEndpointRoutingPort;
    state.providerEndpointRoutingPort ??= createProviderEndpointRoutingPort?.({
        appVersion: version,
        env,
        projectConfigPath: deps.projectConfigPath,
        skipUserConfig: deps.skipUserConfig,
        userConfigPath: deps.userConfigPath,
        workingDirectory,
    });
    return {
        appEnv,
        configuredDefaultModelSelection,
        createAppFactory,
        providerRegistryRuntime,
        sessionId,
        workingDirectory,
    };
}
