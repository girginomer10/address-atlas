import { readdir, rm, stat } from "node:fs/promises";
import path from "node:path";

const root = process.cwd();
const duplicatePattern = / \d+\.[^/]+$/;
const targets = [
  path.join(root, ".next"),
  path.join(root, "src/generated/prisma")
];

await Promise.allSettled([
  rm(path.join(root, "tsconfig.tsbuildinfo"), { force: true }),
  rm(path.join(root, ".next/cache/.tsbuildinfo"), { force: true })
]);

for (const target of targets) {
  await clean(target);
}

async function clean(filePath) {
  const info = await stat(filePath).catch(() => null);
  if (!info) return;

  if (info.isDirectory()) {
    const entries = await readdir(filePath);
    await Promise.all(entries.map((entry) => clean(path.join(filePath, entry))));
    return;
  }

  if (duplicatePattern.test(path.basename(filePath))) {
    await rm(filePath, { force: true });
  }
}
