import { spawnSync } from "node:child_process";
import { ensureSqliteDatabase } from "./ensure-sqlite-db.mjs";

const TEST_DATABASE_URL = "file:./.data/address-atlas.test.db";
const env = {
  ...process.env,
  DATABASE_URL: TEST_DATABASE_URL,
  NODE_ENV: "test"
};

process.env.DATABASE_URL = TEST_DATABASE_URL;
process.env.NODE_ENV = "test";
ensureSqliteDatabase(TEST_DATABASE_URL);

run("prisma", ["generate"]);
run("prisma", ["db", "push", "--force-reset"]);
run("vitest", ["run"]);

function run(command, args) {
  const executable = process.platform === "win32" ? `${command}.cmd` : command;
  const result = spawnSync(executable, args, {
    env,
    stdio: "inherit"
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
