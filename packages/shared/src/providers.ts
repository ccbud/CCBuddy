import { z } from "zod";

/**
 * CCbuddy agent 提供方的单一真源。
 *
 * 类型 CCbuddyProvider、运行时 schema ccbuddyProviderSchema 都从这里派生,
 * 避免各处内联 z.enum([...]) 副本随新增/删除 provider 漂移。
 * 本模块只依赖 zod(叶子),可被 validation / ccbuddy-protocol 等无环引用。
 */
const CCBUDDY_PROVIDERS = ["glm"] as const;

export const ccbuddyProviderSchema = z.enum(CCBUDDY_PROVIDERS);

export type CCbuddyProvider = (typeof CCBUDDY_PROVIDERS)[number];
