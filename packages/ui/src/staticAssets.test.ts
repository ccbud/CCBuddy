import { access, glob, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

const sourceRoot = fileURLToPath(new URL(".", import.meta.url));
const assetExtension =
  /\.(?:css|svg|png|jpe?g|gif|webp|avif|ico|woff2?|ttf|eot|mp4|webm|mp3|wav)(?:[?#].*)?$/i;

async function sourceFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const groups = await Promise.all(
    entries.map(async (entry) => {
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory()) return sourceFiles(filename);
      return /\.(?:tsx?|css)$/.test(entry.name) && !/\.test\./.test(entry.name) ? [filename] : [];
    }),
  );
  return groups.flat();
}

it("resolves every static local asset and CSS build directive", async () => {
  // 类型声明中的通配符会接受不存在的资源；实际文件检查能在 Vite 构建前暴露遗漏。
  const missing: string[] = [];
  await Promise.all(
    (await sourceFiles(sourceRoot)).map(async (filename) => {
      const source = await readFile(filename, "utf8");
      const isStylesheet = filename.endsWith(".css");
      const expressions = isStylesheet
        ? [
            /@(?:import|plugin|config|source)\s+(?:url\(\s*)?["']([^"']+)["']/g,
            /url\(\s*["']?([^"')\s]+)["']?\s*\)/g,
          ]
        : [/\b(?:import|export)\s+(?:[^"'`;]*?\bfrom\s*)?["']([^"']+)["']/g];
      for (const expression of expressions) {
        for (const match of source.matchAll(expression)) {
          const reference = match[1]!;
          if (
            (!isStylesheet && !assetExtension.test(reference)) ||
            (!reference.startsWith(".") && !reference.startsWith("@/"))
          )
            continue;
          const cleanReference = reference.split(/[?#]/)[0]!;
          const assetPath = cleanReference.startsWith("@/")
            ? path.join(sourceRoot, cleanReference.slice(2))
            : path.resolve(path.dirname(filename), cleanReference);
          try {
            if (/[*?{[]/.test(assetPath)) {
              let found = false;
              for await (const _match of glob(assetPath)) {
                found = true;
                break;
              }
              if (!found) throw new Error("Source glob has no matches");
            } else {
              await access(assetPath);
            }
          } catch {
            missing.push(`${path.relative(sourceRoot, filename)}: ${reference}`);
          }
        }
      }
    }),
  );
  expect(missing.sort()).toEqual([]);
});
