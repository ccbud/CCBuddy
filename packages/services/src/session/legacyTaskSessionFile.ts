import type { CCbuddySessionFile, CCbuddyTaskMeta } from "@ccbuddy/shared";
import {
  ccbuddySessionFileSchema,
  ccbuddyTaskMetaSchema,
  ccbuddyTaskModeSchema,
} from "@ccbuddy/shared";

export type LegacyTaskSessionFile = Omit<CCbuddySessionFile, "meta"> & {
  meta: Omit<CCbuddyTaskMeta, "mode"> & { mode?: CCbuddyTaskMeta["mode"] };
};

const legacyTaskSessionFileSchema = ccbuddySessionFileSchema.extend({
  // Claude 原生迁移会按清洗路径删除 meta.mode。
  // legacy snapshot 读取/写入仍要校验其它必需字段，但不能再强制把被过滤字段补回文件。
  meta: ccbuddyTaskMetaSchema.extend({
    mode: ccbuddyTaskModeSchema.optional(),
  }),
});

export function parseLegacyTaskSessionFile(input: unknown): LegacyTaskSessionFile {
  return legacyTaskSessionFileSchema.parse(input);
}

export function safeParseLegacyTaskSessionFile(input: unknown) {
  return legacyTaskSessionFileSchema.safeParse(input);
}
