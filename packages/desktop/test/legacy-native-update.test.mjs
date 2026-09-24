import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  LEGACY_NATIVE_PLATFORM_KEYS,
  findEscapingSymlinks,
  LEGACY_UPDATER_PUBLIC_KEY,
  formatMinisignKeyId,
  legacyBridgeArchiveName,
  parseMinisignPublicKey,
  verifyLegacyArchiveSignature,
  verifyLegacyNativeManifest,
  writeLegacyNativeManifest,
} from "../scripts/legacy-native-update.mjs";

const version = "2.0.13";
const repository = "ccbud/CCBuddy";
const archiveName = legacyBridgeArchiveName(version);
const archiveBytes = Buffer.from("signed, notarized, stapled bridge app tar.gz");

function createMinisignKey(keyId = randomBytes(8)) {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url");
  const body = Buffer.concat([Buffer.from("Ed"), keyId, raw]).toString("base64");
  const text = `untrusted comment: minisign public key: ${formatMinisignKeyId(keyId)}\n${body}\n`;
  return { keyId, privateKey, encodedPublicKey: Buffer.from(text).toString("base64") };
}

// 与 Tauri signer 输出一致：对 BLAKE2b-512 预哈希签名，再签 signature || trusted comment。
function signLikeTauri(bytes, { keyId, privateKey }) {
  const digest = createHash("blake2b512").update(bytes).digest();
  const signature = sign(null, digest, privateKey);
  const trusted = `timestamp:1790000000\tfile:${archiveName}`;
  const global = sign(null, Buffer.concat([signature, Buffer.from(trusted)]), privateKey);
  const envelope = Buffer.concat([Buffer.from("ED"), keyId, signature]).toString("base64");
  const text = [
    "untrusted comment: signature from tauri secret key",
    envelope,
    `trusted comment: ${trusted}`,
    global.toString("base64"),
    "",
  ].join("\n");
  return Buffer.from(text).toString("base64");
}

async function withDist(key, run, { bytes = archiveBytes, signature } = {}) {
  const distDir = await mkdtemp(join(tmpdir(), "ccbuddy-legacy-update-test-"));
  try {
    await writeFile(join(distDir, archiveName), bytes);
    await writeFile(join(distDir, `${archiveName}.sig`), signature ?? signLikeTauri(bytes, key));
    await run(distDir);
  } finally {
    await rm(distDir, { recursive: true, force: true });
  }
}

test("embedded public key is the minisign key the old native and Tauri clients trust", () => {
  const { keyId } = parseMinisignPublicKey(LEGACY_UPDATER_PUBLIC_KEY);
  assert.equal(formatMinisignKeyId(keyId), "FB130F2908B61575");
});

test("writes latest.json with only arm64 keys pointing at the signed archive", async () => {
  const key = createMinisignKey();
  await withDist(key, async (distDir) => {
    await writeLegacyNativeManifest({
      distDir,
      version,
      repository,
      publicKey: key.encodedPublicKey,
      pubDate: "2026-09-24T00:00:00.000Z",
    });
    const manifest = JSON.parse(await readFile(join(distDir, "latest.json"), "utf8"));
    const sha256 = createHash("sha256").update(archiveBytes).digest("hex");
    const signature = signLikeTauri(archiveBytes, key);
    assert.equal(manifest.version, version);
    assert.equal(manifest.pub_date, "2026-09-24T00:00:00.000Z");
    assert.deepEqual(Object.keys(manifest.platforms), [...LEGACY_NATIVE_PLATFORM_KEYS]);
    assert.equal(manifest.platforms["darwin-x86_64"], undefined);
    for (const entry of Object.values(manifest.platforms)) {
      assert.deepEqual(entry, {
        url: `https://github.com/${repository}/releases/download/v${version}/${archiveName}`,
        signature,
        sha256,
      });
    }
  });
});

test("rejects a signature from any key other than the legacy updater key", async () => {
  const trusted = createMinisignKey();
  const foreign = createMinisignKey();
  await withDist(foreign, async (distDir) => {
    await assert.rejects(
      writeLegacyNativeManifest({
        distDir,
        version,
        repository,
        publicKey: trusted.encodedPublicKey,
      }),
      /is not the legacy key/,
    );
  });
});

test("rejects a same-key-id signature that does not verify", async () => {
  const trusted = createMinisignKey();
  const impostor = createMinisignKey(trusted.keyId);
  await withDist(impostor, async (distDir) => {
    await assert.rejects(
      writeLegacyNativeManifest({
        distDir,
        version,
        repository,
        publicKey: trusted.encodedPublicKey,
      }),
      /does not verify/,
    );
  });
});

test("rejects an archive modified after signing", async () => {
  const key = createMinisignKey();
  await withDist(
    key,
    async (distDir) => {
      await assert.rejects(
        verifyLegacyArchiveSignature(
          join(distDir, archiveName),
          await readFile(join(distDir, `${archiveName}.sig`), "utf8"),
          key.encodedPublicKey,
        ),
        /does not verify/,
      );
    },
    { bytes: Buffer.from("tampered"), signature: signLikeTauri(archiveBytes, key) },
  );
});

test("rejects non-canonical Base64 that the Swift client cannot decode", async () => {
  const key = createMinisignKey();
  // Node 会宽松解码多余字符，Swift 的 Data(base64Encoded:) 则直接失败。
  const nonCanonical = `${signLikeTauri(archiveBytes, key)}A`;
  await withDist(
    key,
    async (distDir) => {
      await assert.rejects(
        writeLegacyNativeManifest({
          distDir,
          version,
          repository,
          publicKey: key.encodedPublicKey,
        }),
        /canonical Base64/,
      );
    },
    { signature: nonCanonical },
  );
});

test("verification rejects a manifest that drifts from the archive or lists Intel keys", async () => {
  const key = createMinisignKey();
  await withDist(key, async (distDir) => {
    await writeLegacyNativeManifest({
      distDir,
      version,
      repository,
      publicKey: key.encodedPublicKey,
    });
    const manifestPath = join(distDir, "latest.json");
    const original = JSON.parse(await readFile(manifestPath, "utf8"));

    const withIntel = structuredClone(original);
    withIntel.platforms["darwin-x86_64"] = withIntel.platforms["darwin-aarch64"];
    await writeFile(manifestPath, JSON.stringify(withIntel));
    await assert.rejects(
      verifyLegacyNativeManifest({ distDir, version, repository, publicKey: key.encodedPublicKey }),
      /must list exactly/,
    );

    const wrongDigest = structuredClone(original);
    wrongDigest.platforms["darwin-aarch64"].sha256 = "0".repeat(64);
    await writeFile(manifestPath, JSON.stringify(wrongDigest));
    await assert.rejects(
      verifyLegacyNativeManifest({ distDir, version, repository, publicKey: key.encodedPublicKey }),
      /darwin-aarch64 does not match/,
    );

    await writeFile(manifestPath, JSON.stringify({ ...original, version: "2.0.12" }));
    await assert.rejects(
      verifyLegacyNativeManifest({ distDir, version, repository, publicKey: key.encodedPublicKey }),
      /mismatched version/,
    );
  });
});

test("reports symlinks the old client's extractor would reject", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-legacy-symlink-test-"));
  try {
    const app = join(root, "CCbuddy.app");
    const versions = join(app, "Contents/Frameworks/Electron Framework.framework/Versions");
    await mkdir(join(versions, "A"), { recursive: true });
    await writeFile(join(root, "outside"), "x");
    // Electron 框架内部的相对链接合法。
    await symlink("A", join(versions, "Current"));
    await symlink("../outside", join(app, "Contents/escape"));
    await symlink("missing", join(app, "Contents/dangling"));
    assert.deepEqual(await findEscapingSymlinks(app), ["Contents/dangling", "Contents/escape"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
