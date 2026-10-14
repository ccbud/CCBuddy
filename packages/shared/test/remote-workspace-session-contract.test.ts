import assert from "node:assert/strict";
import { test } from "node:test";
import { z } from "zod";
import { PlatformChannels } from "../src/channels.ts";
import { buildCCbuddyEndpointUrls } from "../src/ccbuddyEndpoint.ts";
import { PROTOCOL_V4_LIMITS, V4_WIRE_PROTOCOL_VERSION } from "../src/ccbuddy-protocol-v4/core.ts";
import {
  encodeTopicWireFrames,
  measureTopicNotificationEnvelopeBytes,
} from "../src/ccbuddy-protocol-v4/wire-codec.ts";
import { TopicWireFrameAssembler } from "../src/ccbuddy-protocol-v4/wire-assembler.ts";
import { clientHelloSchema } from "../src/ccbuddy-protocol-v4/transport.ts";
import * as validation from "../src/validation.ts";
import * as sessionTelemetry from "../src/sessionCreateTelemetry.ts";

test("remote workspace binding retains identity without phone metadata", () => {
  const target = {
    workspacePath: "/workspace/project",
    workspaceIdentity: "ssh:fixture:/workspace/project",
    remoteSessionId: "remote-session-fixture",
  };
  assert.deepEqual(validation.remoteWorkspaceSessionTargetsSchema.parse([target]), [target]);
  assert.equal(
    validation.remoteWorkspaceSessionTargetsSchema.safeParse([{ ...target, label: "phone" }])
      .success,
    false,
  );
  assert.equal(
    validation.remoteWorkspaceSessionTargetsSchema.safeParse([{ ...target, remoteSessionId: "" }])
      .success,
    false,
  );
  assert.equal(
    validation.remoteWorkspaceSessionTargetsSchema.safeParse([
      { workspacePath: target.workspacePath, remoteSessionId: target.remoteSessionId },
    ]).success,
    true,
  );
});

test("platform channels and endpoint results expose ordinary remote sessions only", () => {
  assert.equal(
    PlatformChannels.SyncRemoteWorkspaceSessions,
    "ccbuddy:sync-remote-workspace-sessions",
  );
  assert.equal(
    Object.keys(PlatformChannels).some((key) => key.includes("WebRemoteControl")),
    false,
  );
  const endpoint = buildCCbuddyEndpointUrls("https://example.invalid");
  for (const key of ["remoteUrl", "relayWsUrl", "webRemoteCallbackUrl"]) {
    assert.equal(key in endpoint, false);
  }
  assert.equal(endpoint.webShareCallbackUrl, "https://example.invalid/cn/share/callback");
});

test("old phone settings are discarded while ordinary settings survive", () => {
  const settings = {
    recentProjects: ["/workspace/project"],
    webRemoteControlExternalRelayDevice: { deviceSid: "old-device-fixture" },
    webRemoteControlLastEnabledContext: { workspacePath: "/workspace/project" },
  };
  for (const schema of [validation.appSettingsSchema, validation.appSettingsPatchSchema]) {
    const parsed = schema.parse(settings);
    assert.deepEqual(parsed.recentProjects, settings.recentProjects);
    assert.equal("webRemoteControlExternalRelayDevice" in parsed, false);
    assert.equal("webRemoteControlLastEnabledContext" in parsed, false);
  }
});

test("ordinary Host attachments retain both delivery modes", () => {
  for (const clientMode of ["desktop-continuous", "web-remote-replayable"]) {
    assert.equal(
      validation.hostAttachServicePortMessageSchema.safeParse({
        type: "attach-service-port",
        requestId: "attach-fixture",
        attachmentId: "attachment-fixture",
        clientMode,
        scope: { kind: "local" },
      }).success,
      true,
    );
  }
});

test("live hello accepts current Desktop/Web clients without mobile control categories", () => {
  const hello = {
    kind: "clientHello",
    protocolVersion: V4_WIRE_PROTOCOL_VERSION,
    clientId: "client-fixture",
    appVersion: "2.0.12",
  };
  for (const clientKind of ["desktop", "web"]) {
    assert.equal(clientHelloSchema.safeParse({ ...hello, clientKind }).success, true);
  }
  for (const clientKind of ["mobileRemote", "mobileApp"]) {
    assert.equal(clientHelloSchema.safeParse({ ...hello, clientKind }).success, false);
  }
});

test("Host automation telemetry remains strict after removing phone forwarding", () => {
  assert.equal("sessionCreateTelemetrySchema" in sessionTelemetry, false);
  const event = {
    elementName: "session_create",
    eventRegion: "app",
    eventType: "result",
    talkId: "talk-fixture",
    messageId: "message-fixture",
    context: { clientTimezone: "UTC", clientLanguage: "en-US", screenResolution: "1280x720" },
    eventExtraDetail: {
      create_source: "automation_scheduled",
      client_kind: "desktop",
      workspace_kind: "remote",
      remote_kind: "ssh",
    },
  };
  assert.deepEqual(sessionTelemetry.automationSessionCreateTelemetrySchema.parse(event), event);
  assert.equal(
    sessionTelemetry.automationSessionCreateTelemetrySchema.safeParse({
      ...event,
      eventExtraDetail: { ...event.eventExtraDetail, client_kind: "mobile" },
    }).success,
    false,
  );
});

const frameSchema = z.object({ topic: z.string(), subscriptionId: z.string(), body: z.string() });
const wireOptions = {
  deliveryKind: "online" as const,
  topic: "conversation-fixture",
  subscriptionId: "subscription-fixture",
  logicalFrameId: "frame-fixture",
  logicalFrameOrdinal: 1,
  measurePhysicalFrameBytes: (wire: Parameters<typeof measureTopicNotificationEnvelopeBytes>[0]) =>
    measureTopicNotificationEnvelopeBytes(wire).maxBytes,
};

test("ordinary RPC frames above the old phone base64 budget stay complete", () => {
  const frame = {
    topic: wireOptions.topic,
    subscriptionId: wireOptions.subscriptionId,
    body: "x".repeat(900_000),
  };
  const wires = encodeTopicWireFrames(frame, wireOptions);
  assert.equal(wires.length, 1);
  assert.equal(wires[0]!.kind, "complete");
  const measured = measureTopicNotificationEnvelopeBytes(wires[0]!);
  assert.equal(measured.maxBytes, Math.max(measured.cliNdjsonBytes, measured.channelSocketBytes));
  assert.equal("mobileRelayBytes" in measured, false);
  const assembler = new TopicWireFrameAssembler(frameSchema);
  assert.deepEqual(assembler.accept(wires[0]!), [
    { kind: "complete", frame, deliveryKind: "online" },
  ]);
});

test("current physical limits reject oversize complete frames and reassemble CRC fragments", () => {
  const frame = {
    topic: wireOptions.topic,
    subscriptionId: wireOptions.subscriptionId,
    body: "界".repeat(400_000),
  };
  const unsafeComplete = {
    ...wireOptions,
    wireVersion: V4_WIRE_PROTOCOL_VERSION,
    kind: "complete" as const,
    frame,
  };
  const { measurePhysicalFrameBytes: _measure, ...complete } = unsafeComplete;
  const rejected = new TopicWireFrameAssembler(frameSchema).accept(complete);
  assert.equal(rejected[0]?.kind, "fault");
  assert.equal(
    rejected[0]?.kind === "fault" && rejected[0].fault.reasonCode,
    "proto.frameEnvelopeTooLarge",
  );

  const wires = encodeTopicWireFrames(frame, wireOptions);
  assert.ok(wires.length > 1);
  assert.ok(wires.every((wire) => wire.kind === "fragment"));
  assert.ok(
    wires.every(
      (wire) =>
        measureTopicNotificationEnvelopeBytes(wire).maxBytes <= PROTOCOL_V4_LIMITS.maxFrameBytes,
    ),
  );
  const assembler = new TopicWireFrameAssembler(frameSchema);
  assert.deepEqual(
    wires.flatMap((wire) => assembler.accept(wire)),
    [{ kind: "complete", frame, deliveryKind: "online" }],
  );

  const corrupted = wires.map((wire, index) =>
    index === 0 && wire.kind === "fragment"
      ? {
          ...wire,
          dataBase64: `${wire.dataBase64[0] === "A" ? "B" : "A"}${wire.dataBase64.slice(1)}`,
        }
      : wire,
  );
  const corruptAssembler = new TopicWireFrameAssembler(frameSchema);
  const corruptEvents = corrupted.flatMap((wire) => corruptAssembler.accept(wire));
  assert.equal(
    corruptEvents.some((event) => event.kind === "complete"),
    false,
  );
  assert.equal(
    corruptEvents.some((event) => event.kind === "fault"),
    true,
  );
});
