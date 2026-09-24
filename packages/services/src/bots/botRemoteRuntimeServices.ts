import {
  ChannelClient,
  MessagePortProtocol,
  ProxyChannel,
  type MessagePortLike,
  type MessagePortPayload,
} from "@ccbuddy/rpc";
import {
  ICCbuddyTaskService,
  type ICCbuddyTaskService as ICCbuddyTaskServiceShape,
} from "#src/session/ccbuddyTaskService.js";
import {
  ICCbuddyAgentService,
  type ICCbuddyAgentService as ICCbuddyAgentServiceShape,
} from "#src/ccbuddy-agent/ccbuddyAgent.js";
import {
  ICCbuddySessionService,
  type ICCbuddySessionService as ICCbuddySessionServiceShape,
} from "#src/ccbuddy-session/ccbuddySession.js";
import {
  IModelSelectionService,
  type IModelSelectionService as IModelSelectionServiceShape,
} from "#src/model-provider/providerFacadeServices.js";

interface PortLike {
  on?(event: "message", listener: (event: { data: MessagePortPayload }) => void): void;
  off?(event: "message", listener: (event: { data: MessagePortPayload }) => void): void;
  addEventListener?(
    event: "message",
    listener: (event: { data: MessagePortPayload }) => void,
  ): void;
  removeEventListener?(
    event: "message",
    listener: (event: { data: MessagePortPayload }) => void,
  ): void;
  postMessage(message: MessagePortPayload): void;
  start?(): void;
  close?(): void;
}

function toMessagePortLike(port: PortLike): MessagePortLike {
  return {
    addEventListener(type, listener) {
      if (port.addEventListener) {
        port.addEventListener(type, listener);
        return;
      }
      port.on?.(type, listener);
    },
    removeEventListener(type, listener) {
      if (port.removeEventListener) {
        port.removeEventListener(type, listener);
        return;
      }
      port.off?.(type, listener);
    },
    postMessage(data) {
      port.postMessage(data);
    },
    start() {
      port.start?.();
    },
    close() {
      port.close?.();
    },
  };
}

export interface RemoteBotWorkspaceRuntimeServices {
  ccbuddyAgentService: ICCbuddyAgentServiceShape;
  ccbuddyTaskService: ICCbuddyTaskServiceShape;
  ccbuddySessionService: ICCbuddySessionServiceShape;
  modelSelectionService: IModelSelectionServiceShape;
}

export function createRemoteRuntimeServicesFromPort(
  port: unknown,
): RemoteBotWorkspaceRuntimeServices {
  const protocol = new MessagePortProtocol(toMessagePortLike(port as PortLike));
  const client = new ChannelClient(protocol);
  return {
    ccbuddyAgentService: ProxyChannel.toService<ICCbuddyAgentServiceShape>(
      client.getChannel(ICCbuddyAgentService.channelName),
    ),
    ccbuddyTaskService: ProxyChannel.toService<ICCbuddyTaskServiceShape>(
      client.getChannel(ICCbuddyTaskService.channelName),
    ),
    ccbuddySessionService: ProxyChannel.toService<ICCbuddySessionServiceShape>(
      client.getChannel(ICCbuddySessionService.channelName),
    ),
    modelSelectionService: ProxyChannel.toService<IModelSelectionServiceShape>(
      client.getChannel(IModelSelectionService.channelName),
    ),
  };
}
