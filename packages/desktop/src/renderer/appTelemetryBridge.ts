import type { TelemetryRendererContext } from "@ccbuddy/shared";

interface AppTelemetryBridge {
  syncTelemetryContext(context: TelemetryRendererContext): void;
}

interface AppTelemetryBridgeDependencies {
  bridge: AppTelemetryBridge;
  createRendererContext: () => TelemetryRendererContext;
}

export function syncAppTelemetryContext({
  bridge,
  createRendererContext,
}: AppTelemetryBridgeDependencies): void {
  bridge.syncTelemetryContext(createRendererContext());
}
