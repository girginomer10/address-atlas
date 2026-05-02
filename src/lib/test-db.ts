import { prisma } from "./db";

const TEST_DATABASE_NAME = "address-atlas.test.db";

export function assertTestDatabase() {
  const url = process.env.DATABASE_URL ?? "";
  if (!url.includes(TEST_DATABASE_NAME)) {
    throw new Error(`Refusing to mutate non-test database: ${url || "DATABASE_URL is not set"}`);
  }
}

export async function clearTestDatabase() {
  assertTestDatabase();
  await prisma.$transaction([
    prisma.holding.deleteMany(),
    prisma.exchangeSnapshot.deleteMany(),
    prisma.exchangeConnection.deleteMany(),
    prisma.scanRun.deleteMany(),
    prisma.walletAddress.deleteMany(),
    prisma.preference.deleteMany(),
    prisma.vault.deleteMany()
  ]);
}
