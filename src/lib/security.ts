import { createCipheriv, createDecipheriv, createHash, pbkdf2Sync, randomBytes, timingSafeEqual } from "node:crypto";
import { prisma } from "./db";

const VAULT_ID = "local";
const KDF_ITERATIONS = 210_000;
const KEY_BYTES = 32;
const DIGEST = "sha256";
const VERIFIER_TEXT = "address-atlas-vault";

export interface EncryptedPayload {
  v: 1;
  iv: string;
  tag: string;
  data: string;
}

export function containsSensitiveSecret(value: string) {
  const normalized = value.trim();
  if (!normalized) return false;

  if (/xprv|xpub|seed phrase|mnemonic|private key/i.test(normalized)) return true;
  if (/\b[0-9a-f]{64}\b/i.test(normalized) && !/^0x[0-9a-f]{40}$/i.test(normalized)) return true;

  const words = normalized
    .split(/\s+/g)
    .map((word) => word.replace(/[^a-z]/gi, ""))
    .filter((word) => word.length >= 2);

  return words.length >= 12;
}

export async function hasVault() {
  return Boolean(await prisma.vault.findUnique({ where: { id: VAULT_ID } }));
}

export async function ensureVault(passphrase: string) {
  const existing = await prisma.vault.findUnique({ where: { id: VAULT_ID } });
  if (existing) {
    verifyPassphrase(existing.salt, existing.verifier, passphrase);
    return existing;
  }

  assertPassphrase(passphrase);
  const salt = randomBytes(16).toString("base64");
  const key = deriveKey(passphrase, salt);
  const verifier = verifierForKey(key);

  return prisma.vault.create({
    data: {
      id: VAULT_ID,
      salt,
      verifier
    }
  });
}

export async function encryptForVault(value: unknown, passphrase: string) {
  const vault = await ensureVault(passphrase);
  const key = deriveKey(passphrase, vault.salt);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const plaintext = Buffer.from(JSON.stringify(value), "utf8");
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);

  return JSON.stringify({
    v: 1,
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    data: encrypted.toString("base64")
  } satisfies EncryptedPayload);
}

export async function decryptFromVault<T>(encryptedValue: string, passphrase: string): Promise<T> {
  const vault = await prisma.vault.findUnique({ where: { id: VAULT_ID } });
  if (!vault) throw new Error("Vault is not initialized.");
  verifyPassphrase(vault.salt, vault.verifier, passphrase);

  const payload = JSON.parse(encryptedValue) as EncryptedPayload;
  const key = deriveKey(passphrase, vault.salt);
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(payload.iv, "base64"));
  decipher.setAuthTag(Buffer.from(payload.tag, "base64"));
  const decrypted = Buffer.concat([
    decipher.update(Buffer.from(payload.data, "base64")),
    decipher.final()
  ]);

  return JSON.parse(decrypted.toString("utf8")) as T;
}

export async function clearVault() {
  await prisma.vault.deleteMany();
}

function assertPassphrase(passphrase: string) {
  if (passphrase.trim().length < 8) {
    throw new Error("Vault passphrase must be at least 8 characters.");
  }
}

function deriveKey(passphrase: string, salt: string) {
  assertPassphrase(passphrase);
  return pbkdf2Sync(passphrase, Buffer.from(salt, "base64"), KDF_ITERATIONS, KEY_BYTES, DIGEST);
}

function verifierForKey(key: Buffer) {
  return createHash("sha256").update(key).update(VERIFIER_TEXT).digest("base64");
}

function verifyPassphrase(salt: string, verifier: string, passphrase: string) {
  const computed = Buffer.from(verifierForKey(deriveKey(passphrase, salt)), "base64");
  const stored = Buffer.from(verifier, "base64");
  if (stored.length !== computed.length || !timingSafeEqual(stored, computed)) {
    throw new Error("Vault passphrase is incorrect.");
  }
}
