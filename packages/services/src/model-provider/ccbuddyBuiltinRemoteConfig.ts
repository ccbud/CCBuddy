import {
  downloadCCbuddyBuiltinRelease,
  type CCbuddyBuiltinDownloadResult,
} from "@ccbuddy/provider-node";
import type { ApiClient, CCbuddyJwtTokenResolver } from "@ccbuddy/shared";

export interface FetchCCbuddyBuiltinRemoteReleaseOptions {
  readonly apiClient: ApiClient;
  readonly endpointOrigin: string;
  readonly appVersion: string;
  readonly platform: string;
  readonly signal?: AbortSignal;
  readonly resolveCCbuddyJwtToken?: CCbuddyJwtTokenResolver;
  readonly reuseUrl?: string;
}

/** Services 仅注入既有网络装配；URL、预算与 Release 校验由 provider-node 唯一实现。 */
export async function fetchCCbuddyBuiltinRemoteRelease(
  options: FetchCCbuddyBuiltinRemoteReleaseOptions,
): Promise<CCbuddyBuiltinDownloadResult> {
  return downloadCCbuddyBuiltinRelease({
    endpointOrigin: options.endpointOrigin,
    appVersion: options.appVersion,
    platform: options.platform,
    signal: options.signal,
    resolveCCbuddyJwtToken: options.resolveCCbuddyJwtToken,
    request: (url, init) => options.apiClient.request(url, init),
    ...(options.reuseUrl ? { reuseUrl: options.reuseUrl } : {}),
  });
}
