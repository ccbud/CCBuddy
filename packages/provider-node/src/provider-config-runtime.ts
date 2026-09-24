import {
  ProviderConfigService,
  type ProviderConfigLayerSnapshot,
  type ProviderConfigLayerUpdate,
} from "@ccbuddy/provider";
import { NodeCCbuddyBuiltinProviderConfigSource } from "./ccbuddy-builtin-provider-config-source.js";
import {
  EndpointScopedCCbuddyBuiltinSource,
  type EndpointScopedCCbuddyBuiltinSourceOptions,
} from "./endpoint-scoped-ccbuddy-builtin-source.js";
import {
  CCbuddyBuiltinRemoteSynchronizer,
  type CCbuddyBuiltinRemoteSynchronizerOptions,
  type CCbuddyBuiltinRefreshResult,
} from "./ccbuddy-builtin-remote-synchronizer.js";
import {
  NodePersonalProviderConfigRepository,
  type PersonalProviderConfigRecoveryEvent,
} from "./personal-provider-config-repository.js";

export interface NodeProviderConfigRuntimeOptions {
  readonly ccbuddyBuiltinFilePath: string;
  readonly ccbuddyBuiltinActiveFilePath?: string;
  readonly ccbuddyBuiltinRemote?: Omit<CCbuddyBuiltinRemoteSynchronizerOptions, "source">;
  readonly ccbuddyBuiltinEnvironment?: Omit<
    EndpointScopedCCbuddyBuiltinSourceOptions,
    "bundledFilePath"
  >;
  readonly onCCbuddyBuiltinRefreshError?: (error: unknown) => void;
  readonly onPersonalConfigRecovery?: (event: PersonalProviderConfigRecoveryEvent) => void;
  readonly onPersonalConfigPollingError?: (error: unknown) => void;
  readonly personalFilePath: string;
  readonly personalPollingIntervalMs?: number | false;
  readonly importLegacy?: (
    ccbuddyBuiltin: ProviderConfigLayerSnapshot,
  ) => Promise<ProviderConfigLayerUpdate | null>;
  readonly watch?: boolean;
}

/** 组装一个 Node.js 进程内共享的 CCbuddy Built-in/Personal Config 运行边界。 */
export class NodeProviderConfigRuntime {
  readonly configService: ProviderConfigService;
  readonly #ccbuddyBuiltinSource:
    | NodeCCbuddyBuiltinProviderConfigSource
    | EndpointScopedCCbuddyBuiltinSource;
  readonly #personalRepository: NodePersonalProviderConfigRepository;
  readonly #remoteSynchronizer?: CCbuddyBuiltinRemoteSynchronizer;
  readonly #onRemoteRefreshError?: (error: unknown) => void;
  #startPromise: Promise<void> | null = null;
  #disposed = false;
  readonly #checkListeners = new Set<() => Promise<void>>();
  #checkTimer: ReturnType<typeof setInterval> | null = null;
  #checkInFlight: Promise<void> | null = null;

  constructor(options: NodeProviderConfigRuntimeOptions) {
    this.#ccbuddyBuiltinSource = options.ccbuddyBuiltinEnvironment
      ? new EndpointScopedCCbuddyBuiltinSource({
          bundledFilePath: options.ccbuddyBuiltinFilePath,
          ...options.ccbuddyBuiltinEnvironment,
        })
      : new NodeCCbuddyBuiltinProviderConfigSource({
          bundledFilePath: options.ccbuddyBuiltinFilePath,
          activeFilePath: options.ccbuddyBuiltinActiveFilePath,
          watch: options.watch,
        });
    this.#remoteSynchronizer =
      options.ccbuddyBuiltinRemote &&
      this.#ccbuddyBuiltinSource instanceof NodeCCbuddyBuiltinProviderConfigSource
        ? new CCbuddyBuiltinRemoteSynchronizer({
            source: this.#ccbuddyBuiltinSource,
            ...options.ccbuddyBuiltinRemote,
          })
        : undefined;
    this.#onRemoteRefreshError = options.onCCbuddyBuiltinRefreshError;
    this.#personalRepository = new NodePersonalProviderConfigRepository({
      filePath: options.personalFilePath,
      onRecovery: options.onPersonalConfigRecovery,
      onPollingError: options.onPersonalConfigPollingError,
      pollingIntervalMs: options.personalPollingIntervalMs,
      ...(options.importLegacy
        ? {
            importLegacy: async () =>
              options.importLegacy!(await this.#ccbuddyBuiltinSource.read()),
          }
        : {}),
    });
    this.configService = new ProviderConfigService({
      ccbuddyBuiltinSource: this.#ccbuddyBuiltinSource,
      personalRepository: this.#personalRepository,
    });
  }

  resolveCCbuddyBuiltinActiveFilePath(): Promise<string> {
    return this.#ccbuddyBuiltinSource instanceof NodeCCbuddyBuiltinProviderConfigSource
      ? Promise.resolve(this.#ccbuddyBuiltinSource.activeFilePath)
      : this.#ccbuddyBuiltinSource.resolveActiveFilePath();
  }

  get personalRepository(): import("@ccbuddy/provider").PersonalProviderConfigRepository {
    return this.#personalRepository;
  }

  /** Environment 同一周期检查中恢复未对齐依赖，不被下载 TTL 或失败挡住。 */
  onDidCheckCCbuddyBuiltin(listener: () => Promise<void>): () => void {
    this.#checkListeners.add(listener);
    return () => this.#checkListeners.delete(listener);
  }

  start(): Promise<void> {
    if (this.#disposed) throw new Error("NodeProviderConfigRuntime 已 dispose");
    if (this.#startPromise) return this.#startPromise;
    const startPromise = this.configService.read().then(() => {
      if (this.#disposed) return;
      void this.#checkBackground();
      // Managed Worker 无下载配置也无恢复 owner，不建立周期任务。
      if (
        this.#remoteSynchronizer ||
        this.#ccbuddyBuiltinSource instanceof EndpointScopedCCbuddyBuiltinSource ||
        this.#checkListeners.size > 0
      ) {
        this.#checkTimer = setInterval(() => {
          void this.#checkBackground();
        }, 60_000);
        this.#checkTimer.unref?.();
      }
    });
    this.#startPromise = startPromise;
    void startPromise.catch(() => {
      if (this.#startPromise === startPromise) this.#startPromise = null;
    });
    return startPromise;
  }

  refreshCCbuddyBuiltin(options?: {
    readonly force?: boolean;
  }): Promise<CCbuddyBuiltinRefreshResult> {
    if (this.#disposed) return Promise.resolve("disposed");
    if (this.#ccbuddyBuiltinSource instanceof EndpointScopedCCbuddyBuiltinSource) {
      return this.#ccbuddyBuiltinSource.refresh(options);
    }
    return this.#remoteSynchronizer?.refresh(options) ?? Promise.resolve("skipped");
  }

  #checkBackground(): Promise<void> {
    if (this.#disposed) return Promise.resolve();
    if (this.#checkInFlight) return this.#checkInFlight;
    const check = Promise.allSettled([
      this.refreshCCbuddyBuiltin(),
      ...[...this.#checkListeners].map((listener) => Promise.resolve().then(listener)),
    ])
      .then((results) => {
        if (this.#disposed) return;
        for (const result of results)
          if (result.status === "rejected") this.#onRemoteRefreshError?.(result.reason);
      })
      .finally(() => {
        if (this.#checkInFlight === check) this.#checkInFlight = null;
      });
    this.#checkInFlight = check;
    return check;
  }

  dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    if (this.#checkTimer) clearInterval(this.#checkTimer);
    this.#checkTimer = null;
    this.#checkListeners.clear();
    this.#remoteSynchronizer?.dispose();
    this.configService.dispose();
    this.#personalRepository.dispose();
    this.#ccbuddyBuiltinSource.dispose();
  }
}

export function createNodeProviderConfigRuntime(
  options: NodeProviderConfigRuntimeOptions,
): NodeProviderConfigRuntime {
  return new NodeProviderConfigRuntime(options);
}
