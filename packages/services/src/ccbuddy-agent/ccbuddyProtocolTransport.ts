import type { Event, IDisposable } from "@ccbuddy/rpc";
import type { CCbuddyProtocolMessage } from "@ccbuddy/shared";

export type CCbuddyProtocolTransportKind = "stdio" | "websocket" | "memory";

export interface CCbuddyProtocolTransportClosedEvent {
  code?: number | null;
  signal?: NodeJS.Signals | null;
  reason?: string;
}

export interface CCbuddyProtocolTransport extends IDisposable {
  readonly kind: CCbuddyProtocolTransportKind;
  readonly onMessage: Event<CCbuddyProtocolMessage>;
  readonly onClose: Event<CCbuddyProtocolTransportClosedEvent>;
  send(message: CCbuddyProtocolMessage): Promise<void>;
  disposeAndWait?(): Promise<void>;
}
