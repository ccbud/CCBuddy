import { describe, expect, it, vi } from "vitest";
import type { Logger } from "@ccbuddy/contracts";
import type { SharedCCbuddyCredentialStore } from "@ccbuddy/adapters/auth";
import { resolveProcessProviderEndpointRoutingPort } from "../src/provider-endpoint-routing.js";

describe("resolveProcessProviderEndpointRoutingPort", () => {
  it("keeps injected credential owners separate while reusing one owner's port", () => {
    const firstStore = { load: vi.fn(async () => null) } as unknown as SharedCCbuddyCredentialStore;
    const secondStore = { load: vi.fn(async () => null) } as unknown as SharedCCbuddyCredentialStore;
    const create = (credentialStore: SharedCCbuddyCredentialStore) =>
      resolveProcessProviderEndpointRoutingPort({
        env: { CCBUDDY_ENV: "production", CCBUDDY_BASE_URL: "https://credential-owner.example.test" },
        logger,
        network: {},
        credentialStore,
      });
    expect(create(firstStore)).toBe(create(firstStore));
    expect(create(firstStore)).not.toBe(create(secondStore));
  });
  it("shares one process snapshot owner for the same endpoint and network policy", () => {
    const env = {
      CCBUDDY_ENV: "test",
      CCBUDDY_TEST_BASE_URL: "https://routing-config.example.test",
    };
    const network = {
      httpProxy: "http://proxy.example.test:8080",
      noProxy: "routing-config.example.test",
    };

    const first = resolveProcessProviderEndpointRoutingPort({
      appVersion: "1.2.3",
      env,
      logger,
      network,
    });
    const second = resolveProcessProviderEndpointRoutingPort({
      appVersion: "9.9.9",
      env: { ...env },
      logger,
      network: { ...network },
    });

    expect(second).toBe(first);
  });

  it("isolates ports when the endpoint origin changes", () => {
    const create = (origin: string) =>
      resolveProcessProviderEndpointRoutingPort({
        env: { CCBUDDY_ENV: "production", CCBUDDY_BASE_URL: origin },
        logger,
        network: {},
      });
    expect(create("https://first.example.test")).not.toBe(create("https://second.example.test"));
  });

  it("isolates snapshots when the network policy changes", () => {
    const env = {
      CCBUDDY_ENV: "test",
      CCBUDDY_TEST_BASE_URL: "https://routing-config-network.example.test",
    };
    const direct = resolveProcessProviderEndpointRoutingPort({
      appVersion: "1.2.3",
      env,
      logger,
      network: {},
    });
    const proxied = resolveProcessProviderEndpointRoutingPort({
      appVersion: "1.2.3",
      env,
      logger,
      network: { httpProxy: "http://proxy.example.test:8080" },
    });

    expect(proxied).not.toBe(direct);
  });
});

const logger: Logger = {
  child: () => logger,
  debug: vi.fn(),
  error: vi.fn(),
  info: vi.fn(),
  warn: vi.fn(),
};
