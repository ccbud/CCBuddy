#!/usr/bin/env node

// 修复原因：2.0.3–2.0.9 原生版与 Tauri 1.3.9 的更新器已冻结，只读取
// releases/latest/download/latest.json；Electron 发布只产出 latest-mac.yml，
// 旧客户端因此 404 无法升级。本脚本为每个 Electron 发布生成旧更新器能验证的
// latest.json（契约见 docs/specs/legacy-native-update-bridge.md）。

import { createHash, createPublicKey, verify } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, readdir, readFile, realpath, stat, writeFile } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

// 与旧客户端 v2.0.5 源码中硬编码的更新公钥一致（bundle id 与 Team 校验见
// package-legacy-native-bridge.sh），不能随新应用身份变化。
export const LEGACY_UPDATER_PUBLIC_KEY =
  "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEZCMTMwRjI5MDhCNjE1NzUKUldSMUZiWUlLUThUK3kybFBUU3ljMWUyenAwR3U1NjdPZm1jM25ocndIclhLYUFGTU92KzJXRFQK";
const LEGACY_NATIVE_MANIFEST_NAME = "latest.json";
// Electron 发布只有 arm64；不写 x86_64 键，Intel 旧客户端进入手动下载而不是装上无法运行的包。
export const LEGACY_NATIVE_PLATFORM_KEYS = Object.freeze(["darwin-aarch64-app", "darwin-aarch64"]);

const MAX_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAX_SIGNATURE_BYTES = 16 * 1024;
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export function legacyBridgeArchiveName(version) {
  assertVersion(version);
  return `CCbuddy-${version}-legacy-mac-arm64.app.tar.gz`;
}

function assertVersion(version) {
  if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
    throw new Error(`Invalid release version: ${version}`);
  }
}

function assertRepository(repository) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository ?? "")) {
    throw new Error(`Invalid repository: ${repository}`);
  }
}

// Swift 的 Data(base64Encoded:) 要求补齐 padding，这里只接受规范 Base64，
// 避免 Node 宽松解码通过、旧客户端却解码失败。
function decodeCanonicalBase64(value, label) {
  const decoded = Buffer.from(value, "base64");
  if (decoded.length === 0 || decoded.toString("base64") !== value) {
    throw new Error(`${label} is not canonical Base64`);
  }
  return decoded;
}

// 与 Swift 的 split(whereSeparator: \.isNewline) 一致：丢弃空行。
function splitLines(text) {
  return text.split(/[\r\n]+/).filter((line) => line.length > 0);
}

export function parseMinisignPublicKey(encodedPublicKey) {
  const text = decodeCanonicalBase64(encodedPublicKey, "Updater public key").toString("utf8");
  const lines = splitLines(text);
  const binary = decodeCanonicalBase64(lines[1] ?? "", "Updater public key body");
  if (binary.length !== 42 || binary.subarray(0, 2).toString("latin1") !== "Ed") {
    throw new Error("Updater public key is not a minisign Ed25519 key");
  }
  return {
    keyId: binary.subarray(2, 10),
    key: createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, binary.subarray(10, 42)]),
      format: "der",
      type: "spki",
    }),
  };
}

/** minisign 在界面上把 key id 按小端 u64 显示，例如 FB130F2908B61575。 */
export function formatMinisignKeyId(keyId) {
  return Buffer.from(keyId).reverse().toString("hex").toUpperCase();
}

function parseTauriSignature(rawSignature) {
  const encoded = rawSignature.replace(/[\r\n]/g, "").trim();
  if (Buffer.byteLength(encoded) > MAX_SIGNATURE_BYTES) {
    throw new Error("Updater signature is too large");
  }
  const lines = splitLines(decodeCanonicalBase64(encoded, "Updater signature").toString("utf8"));
  if (
    lines.length !== 4 ||
    !lines[0].startsWith("untrusted comment: ") ||
    !lines[2].startsWith("trusted comment: ")
  ) {
    throw new Error("Updater signature must decode to the four-line minisign format");
  }
  const envelope = decodeCanonicalBase64(lines[1], "Signature envelope");
  const globalSignature = decodeCanonicalBase64(lines[3], "Global signature");
  // 旧客户端只接受预哈希（ED）签名。
  if (
    envelope.length !== 74 ||
    envelope.subarray(0, 2).toString("latin1") !== "ED" ||
    globalSignature.length !== 64
  ) {
    throw new Error("Updater signature is not a prehashed minisign Ed25519 signature");
  }
  return {
    encoded,
    keyId: envelope.subarray(2, 10),
    signature: envelope.subarray(10, 74),
    trustedComment: lines[2].slice("trusted comment: ".length),
    globalSignature,
  };
}

async function digestArchive(archivePath) {
  const metadata = await stat(archivePath);
  if (!metadata.isFile() || metadata.size === 0) {
    throw new Error(`Missing or empty legacy archive: ${archivePath}`);
  }
  if (metadata.size > MAX_ARCHIVE_BYTES) {
    throw new Error(`Legacy archive exceeds the old updater's 512 MiB limit: ${archivePath}`);
  }
  const blake2b = createHash("blake2b512");
  const sha256 = createHash("sha256");
  for await (const chunk of createReadStream(archivePath)) {
    blake2b.update(chunk);
    sha256.update(chunk);
  }
  return { blake2b512: blake2b.digest(), sha256: sha256.digest("hex"), size: metadata.size };
}

/** 按旧客户端 MinisignUpdateVerifier 的同一规则验证归档签名。 */
export async function verifyLegacyArchiveSignature(
  archivePath,
  rawSignature,
  encodedPublicKey = LEGACY_UPDATER_PUBLIC_KEY,
) {
  const publicKey = parseMinisignPublicKey(encodedPublicKey);
  const parsed = parseTauriSignature(rawSignature);
  if (!parsed.keyId.equals(publicKey.keyId)) {
    throw new Error(
      `Updater signature key ${formatMinisignKeyId(parsed.keyId)} is not the legacy key ${formatMinisignKeyId(publicKey.keyId)}`,
    );
  }
  const digest = await digestArchive(archivePath);
  const globalPayload = Buffer.concat([parsed.signature, Buffer.from(parsed.trustedComment)]);
  if (
    !verify(null, digest.blake2b512, publicKey.key, parsed.signature) ||
    !verify(null, globalPayload, publicKey.key, parsed.globalSignature)
  ) {
    throw new Error("Updater signature does not verify against the legacy archive");
  }
  return { signature: parsed.encoded, sha256: digest.sha256, size: digest.size };
}

function legacyArchiveUrl({ repository, version, archiveName }) {
  return `https://github.com/${repository}/releases/download/v${version}/${encodeURIComponent(archiveName)}`;
}

function buildLegacyNativeManifest({
  version,
  repository,
  archiveName,
  signature,
  sha256,
  pubDate,
}) {
  assertVersion(version);
  assertRepository(repository);
  const artifact = {
    url: legacyArchiveUrl({ repository, version, archiveName }),
    signature,
    sha256,
  };
  const platforms = {};
  for (const key of LEGACY_NATIVE_PLATFORM_KEYS) platforms[key] = { ...artifact };
  return { version, pub_date: pubDate, platforms };
}

function legacyPaths(distDir, version) {
  const archiveName = legacyBridgeArchiveName(version);
  return {
    archiveName,
    archivePath: join(distDir, archiveName),
    signaturePath: join(distDir, `${archiveName}.sig`),
    manifestPath: join(distDir, LEGACY_NATIVE_MANIFEST_NAME),
  };
}

export async function writeLegacyNativeManifest({
  distDir,
  version,
  repository,
  pubDate = new Date().toISOString(),
  publicKey = LEGACY_UPDATER_PUBLIC_KEY,
}) {
  const paths = legacyPaths(distDir, version);
  const verified = await verifyLegacyArchiveSignature(
    paths.archivePath,
    await readFile(paths.signaturePath, "utf8"),
    publicKey,
  );
  const manifest = buildLegacyNativeManifest({
    version,
    repository,
    archiveName: paths.archiveName,
    signature: verified.signature,
    sha256: verified.sha256,
    pubDate,
  });
  await writeFile(paths.manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  await verifyLegacyNativeManifest({ distDir, version, repository, publicKey });
  return { ...paths, sha256: verified.sha256 };
}

/** 发布前对下载回来的字节重新校验，保证 latest.json、归档和签名三者一致。 */
export async function verifyLegacyNativeManifest({
  distDir,
  version,
  repository,
  publicKey = LEGACY_UPDATER_PUBLIC_KEY,
}) {
  assertVersion(version);
  assertRepository(repository);
  const paths = legacyPaths(distDir, version);
  const manifest = JSON.parse(await readFile(paths.manifestPath, "utf8"));
  if (!manifest || manifest.version !== version || typeof manifest.platforms !== "object") {
    throw new Error("Legacy manifest has a missing or mismatched version/platforms");
  }
  if (Number.isNaN(Date.parse(manifest.pub_date))) {
    throw new Error("Legacy manifest pub_date is not an ISO 8601 date");
  }
  const keys = Object.keys(manifest.platforms).sort();
  if (keys.join(",") !== [...LEGACY_NATIVE_PLATFORM_KEYS].sort().join(",")) {
    throw new Error(`Legacy manifest must list exactly ${LEGACY_NATIVE_PLATFORM_KEYS.join(", ")}`);
  }
  const verified = await verifyLegacyArchiveSignature(
    paths.archivePath,
    await readFile(paths.signaturePath, "utf8"),
    publicKey,
  );
  const expectedUrl = legacyArchiveUrl({ repository, version, archiveName: paths.archiveName });
  for (const key of keys) {
    const entry = manifest.platforms[key];
    if (
      entry?.url !== expectedUrl ||
      entry.signature !== verified.signature ||
      entry.sha256 !== verified.sha256
    ) {
      throw new Error(`Legacy manifest entry ${key} does not match the signed archive`);
    }
  }
  return { ...paths, sha256: verified.sha256 };
}

/**
 * 旧客户端解包后拒绝任何解析到应用包外的符号链接（悬空链接同样无法解析到包内）。
 * 返回违规链接的相对路径，供发布前在打包产物上提前失败。
 */
export async function findEscapingSymlinks(appPath) {
  const root = await realpath(appPath);
  const violations = [];
  async function walk(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const entryPath = join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        const target = await realpath(entryPath).catch(() => null);
        if (!target || !target.startsWith(`${root}${sep}`)) {
          violations.push(entryPath.slice(appPath.length + 1));
        }
      } else if (entry.isDirectory()) {
        await walk(entryPath);
      }
    }
  }
  if (!(await lstat(appPath)).isDirectory()) throw new Error(`Not an app directory: ${appPath}`);
  await walk(appPath);
  return violations.sort();
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  const [command, distDir, version, repository] = process.argv.slice(2);
  const options = { distDir: resolve(distDir ?? ""), version, repository };
  if (command === "write") {
    const result = await writeLegacyNativeManifest(options);
    process.stdout.write(`Wrote ${result.manifestPath} for ${result.archiveName}\n`);
  } else if (command === "verify") {
    const result = await verifyLegacyNativeManifest(options);
    process.stdout.write(`Verified ${result.manifestPath} against ${result.archiveName}\n`);
  } else if (command === "check-symlinks") {
    const violations = await findEscapingSymlinks(resolve(distDir ?? ""));
    if (violations.length > 0) {
      process.stderr.write(`Symlinks escape the app bundle:\n  ${violations.join("\n  ")}\n`);
      process.exit(1);
    }
    process.stdout.write("No symlink escapes the app bundle\n");
  } else {
    process.stderr.write(
      "usage: legacy-native-update.mjs <write|verify> <dist-dir> <version> <owner/repo>\n" +
        "       legacy-native-update.mjs check-symlinks <app>\n",
    );
    process.exit(2);
  }
}
