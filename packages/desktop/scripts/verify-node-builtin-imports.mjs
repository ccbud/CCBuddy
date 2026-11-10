import { readdir, readFile } from "node:fs/promises";
import { isBuiltin } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";

export function findInvalidNodeBuiltinImports(source) {
  const tree = ts.createSourceFile("bundle.js", source, ts.ScriptTarget.Latest, true);
  const invalid = new Set();
  function visit(node) {
    let specifier;
    if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
      specifier = node.moduleSpecifier;
    } else if (
      ts.isCallExpression(node) &&
      (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
        (ts.isIdentifier(node.expression) && node.expression.text === "require"))
    ) {
      specifier = node.arguments[0];
    }
    if (specifier && ts.isStringLiteralLike(specifier)) {
      const name = specifier.text;
      if (!name.startsWith("node:") && !isBuiltin(name) && isBuiltin(`node:${name}`)) {
        invalid.add(name);
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  return [...invalid];
}

export async function verifyNodeBuiltinImports(directory) {
  let files = 0;
  async function visitDirectory(currentDirectory) {
    for (const entry of await readdir(currentDirectory, { withFileTypes: true })) {
      const filename = resolve(currentDirectory, entry.name);
      if (entry.isDirectory()) {
        await visitDirectory(filename);
      } else if (/\.(?:c|m)?js$/.test(entry.name)) {
        const invalid = findInvalidNodeBuiltinImports(await readFile(filename, "utf8"));
        if (invalid.length) {
          throw new Error(`Node builtin protocol missing in ${filename}: ${invalid.join(", ")}`);
        }
        files++;
      }
    }
  }
  await visitDirectory(directory);
  if (files === 0) throw new Error(`No JavaScript bundles found in ${directory}`);
  return files;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const directories = process.argv.slice(2);
  if (!directories.length)
    throw new Error("Usage: verify-node-builtin-imports.mjs <directory> [...]");
  for (const directory of directories) {
    const files = await verifyNodeBuiltinImports(directory);
    console.log(`Node builtin protocols verified: ${directory} (${files} files)`);
  }
}
