import { closeSync, existsSync, mkdirSync, openSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_DATABASE_URL = "file:./.data/address-atlas.db";

export function ensureSqliteDatabase(url = process.env.DATABASE_URL || DEFAULT_DATABASE_URL) {
  if (!url.startsWith("file:") || url === "file::memory:" || url === ":memory:") return;

  const sqlitePath = url.replace(/^file:/, "");
  if (!sqlitePath || sqlitePath === ":memory:") return;

  const absolutePath = sqlitePath.startsWith("/")
    ? sqlitePath
    : resolve(process.cwd(), sqlitePath);

  mkdirSync(dirname(absolutePath), { recursive: true });

  if (!existsSync(absolutePath)) {
    closeSync(openSync(absolutePath, "a"));
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  ensureSqliteDatabase();
}
