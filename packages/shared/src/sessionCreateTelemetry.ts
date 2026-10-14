import { z } from "zod";

export type SessionCreateSource = "group" | "project" | "session";
export type SessionCreateClientKind = "desktop" | "mobile" | "web";

/** 自动化由执行 Host 报告；来源和公共身份由桌面 TelemetryCore 校验并注入。 */
export const automationSessionCreateTelemetrySchema = z
  .object({
    elementName: z.literal("session_create"),
    eventRegion: z.literal("app"),
    eventType: z.literal("result"),
    talkId: z.string().min(1).max(512),
    messageId: z.string().min(1).max(512),
    context: z
      .object({
        clientTimezone: z.string().max(128),
        clientLanguage: z.string().max(128),
        screenResolution: z.string().max(64),
      })
      .strict(),
    eventExtraDetail: z
      .object({
        create_source: z.enum(["automation_idle", "automation_scheduled"]),
        client_kind: z.literal("desktop"),
        workspace_kind: z.enum(["local", "remote"]),
        remote_kind: z.enum(["", "ssh", "wsl", "docker", "server"]),
      })
      .strict(),
  })
  .strict();

export type AutomationSessionCreateTelemetry = z.infer<
  typeof automationSessionCreateTelemetrySchema
>;
