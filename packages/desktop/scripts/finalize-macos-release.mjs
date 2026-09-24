#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { readFile, stat, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import YAML from "yaml";

const desktopDir = resolve(import.meta.dirname, "..");
const workspaceDir = resolve(desktopDir, "../..");

async function sha512(path) {
  const hash = createHash("sha512");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("base64");
}

async function assetInfo(path) {
  const metadata = await stat(path);
  if (!metadata.isFile() || metadata.size === 0) {
    throw new Error(`Missing or empty release asset: ${path}`);
  }
  return { sha512: await sha512(path), size: metadata.size };
}

export async function finalizeMacosRelease(distDir, version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Invalid release version: ${version}`);
  }

  const zipName = `CCbuddy-${version}-mac-arm64.zip`;
  const dmgName = `CCbuddy-${version}-mac-arm64.dmg`;
  const manifestPath = join(distDir, "latest-mac.yml");
  const [rawManifest, zip, dmg] = await Promise.all([
    readFile(manifestPath, "utf8"),
    assetInfo(join(distDir, zipName)),
    assetInfo(join(distDir, dmgName)),
  ]);
  await assetInfo(join(distDir, `${zipName}.blockmap`));

  const manifest = YAML.parse(rawManifest);
  if (!manifest || manifest.version !== version || !Array.isArray(manifest.files)) {
    throw new Error("Builder manifest has a missing or mismatched version/files list");
  }
  const zipEntry = manifest.files.find((entry) => entry?.url === zipName);
  const dmgEntry = manifest.files.find((entry) => entry?.url === dmgName);
  if (
    !zipEntry ||
    !dmgEntry ||
    manifest.files.length !== 2 ||
    manifest.path !== zipName ||
    manifest.sha512 !== zip.sha512 ||
    zipEntry.sha512 !== zip.sha512 ||
    zipEntry.size !== zip.size
  ) {
    throw new Error("Builder manifest does not match the signed ZIP and expected DMG");
  }

  // 修复原因：DMG 公证票据 staple 会改变 DMG 字节，builder 提前生成的 DMG
  // hash 与 blockmap 随即失效。macOS 自动更新只消费未改动的 ZIP，因此最终清单
  // 仅发布 ZIP；已公证并 staple 的 DMG 单独供手动安装。
  manifest.files = [{ url: zipName, sha512: zip.sha512, size: zip.size }];
  manifest.path = zipName;
  manifest.sha512 = zip.sha512;
  await writeFile(manifestPath, YAML.stringify(manifest), "utf8");

  const finalManifest = YAML.parse(await readFile(manifestPath, "utf8"));
  if (
    finalManifest.version !== version ||
    finalManifest.path !== zipName ||
    finalManifest.sha512 !== zip.sha512 ||
    finalManifest.files.length !== 1 ||
    finalManifest.files[0].url !== zipName ||
    finalManifest.files[0].sha512 !== zip.sha512 ||
    finalManifest.files[0].size !== zip.size
  ) {
    throw new Error("Final update manifest failed integrity verification");
  }

  return {
    zipName,
    dmgName,
    manifestName: basename(manifestPath),
    zipSha512: zip.sha512,
    dmgSha512: dmg.sha512,
  };
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  const distDir = resolve(process.argv[2] ?? join(desktopDir, "dist"));
  const packageJson = JSON.parse(await readFile(join(workspaceDir, "package.json"), "utf8"));
  const result = await finalizeMacosRelease(distDir, packageJson.version);
  process.stdout.write(
    `Verified ${result.zipName} and ${result.dmgName}; finalized ${result.manifestName}\n`,
  );
}
