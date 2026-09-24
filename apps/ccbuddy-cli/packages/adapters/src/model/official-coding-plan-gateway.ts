import type { EnvRecord } from "./model-execution.js";

/** Kept as a compatibility type for callers that inspect transport routing. */
export interface OfficialCodingPlanGatewayRoute {
  readonly providerEndpoint: string;
  readonly gatewayPath: string;
}

/** CCbuddy has no subscription gateway routes. */
export const OFFICIAL_CODING_PLAN_GATEWAY_ROUTES: readonly OfficialCodingPlanGatewayRoute[] = [];

export interface OfficialCodingPlanGatewayDecision {
  readonly viaGateway: boolean;
  readonly url: string;
}

export type OfficialCodingPlanGatewayFetch = typeof globalThis.fetch;

/** User-configured model requests retain their exact endpoint. */
export function resolveOfficialCodingPlanGatewayUrl(
  requestUrl: string,
  _env: EnvRecord = process.env,
): OfficialCodingPlanGatewayDecision {
  return { viaGateway: false, url: requestUrl };
}

export function createOfficialCodingPlanGatewayFetch(options: {
  env?: EnvRecord;
  fetch: OfficialCodingPlanGatewayFetch;
}): OfficialCodingPlanGatewayFetch {
  return options.fetch;
}
