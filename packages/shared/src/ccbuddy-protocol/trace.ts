import { z } from "zod";

export const ccbuddyProtocolTraceSchema = z
  .object({
    traceId: z.string().min(1).optional(),
    parentId: z.string().min(1).optional(),
    spanId: z.string().min(1).optional(),
    traceparent: z.string().min(1).optional(),
  })
  .strict();
export type CCbuddyProtocolTrace = z.infer<typeof ccbuddyProtocolTraceSchema>;
