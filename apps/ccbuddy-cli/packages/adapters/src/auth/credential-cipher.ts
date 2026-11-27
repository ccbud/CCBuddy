import {
  createLegacyCredentialCipher,
  type CredentialCipher,
} from "@ccbuddy/shared/credential-security";
export type CCbuddyCredentialCipher = CredentialCipher;
export interface CCbuddyCredentialCipherOptions {
  env?: Record<string, string | undefined>;
}
/** 仅兼容旧格式；正式凭据仓库默认使用系统安全存储。 */
export function createCCbuddyCredentialCipher(options: CCbuddyCredentialCipherOptions = {}) {
  return createLegacyCredentialCipher(options.env);
}
export function isEncryptedCCbuddyCredentialValue(value: string): boolean {
  return value.startsWith("enc:");
}
