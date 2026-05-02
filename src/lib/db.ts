import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { PrismaBetterSqlite3 } from "@prisma/adapter-better-sqlite3";
import { PrismaClient } from "@/generated/prisma/client";

const DEFAULT_DATABASE_URL = "file:./.data/address-atlas.db";

function databaseUrl() {
  return process.env.DATABASE_URL || DEFAULT_DATABASE_URL;
}

function ensureSqliteDirectory(url: string) {
  if (!url.startsWith("file:") || url === "file::memory:" || url === ":memory:") return;
  const sqlitePath = url.replace(/^file:/, "");
  if (!sqlitePath || sqlitePath === ":memory:") return;
  mkdirSync(dirname(resolve(/* turbopackIgnore: true */ process.cwd(), sqlitePath)), { recursive: true });
}

const globalForPrisma = globalThis as unknown as {
  prisma?: PrismaClient;
};

export const prisma =
  globalForPrisma.prisma ??
  (() => {
    const url = databaseUrl();
    ensureSqliteDirectory(url);
    const adapter = new PrismaBetterSqlite3({ url });
    return new PrismaClient({ adapter });
  })();

if (process.env.NODE_ENV !== "production") {
  globalForPrisma.prisma = prisma;
}
