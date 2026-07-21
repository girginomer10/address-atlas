#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import {
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

const MAX_ENV_BYTES = 1_000_000;
const PHASES = ["prepared", "database-committed", "environment-committed", "service-verified"];
const CREDENTIAL_KEYS = new Set([
  "POSTGRES_PASSWORD",
  "POSTGRES_ADMIN_PASSWORD",
  "POSTGRES_RUNTIME_PASSWORD",
  "SYNC_SCHEMA_DATABASE_URL",
  "SYNC_DATABASE_URL"
]);
const STATE_KEYS = [
  "schemaVersion", "phase", "currentEnvHash", "nextEnvHash", "sourceRevision",
  "manageProdSha256", "stateToolSha256", "composeSha256", "provisionSha256",
  "backupToolSha256", "backupPath", "backupSha256", "revision", "webImageId",
  "webContainerId", "caddyContainerId", "postgresContainerId", "postgresVolume"
];

class RotationError extends Error {
  constructor(message, status = 65) {
    super(message);
    this.status = status;
  }
}

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function assertSafeParent(path) {
  if (!isAbsolute(path) || path.includes("\n") || path.includes("\r")) {
    throw new RotationError("Rotation paths must be absolute single-line paths.", 66);
  }
  const parent = dirname(path);
  if (realpathSync(parent) !== parent) {
    throw new RotationError("Rotation path parent must be canonical and symlink-free.", 66);
  }
  const metadata = lstatSync(parent);
  if (!metadata.isDirectory() || metadata.uid !== process.getuid() || (metadata.mode & 0o022) !== 0) {
    throw new RotationError("Rotation path parent must be operator-owned and non-writable by others.", 66);
  }
}

function readPrivateFile(path, maximumBytes = MAX_ENV_BYTES) {
  assertSafeParent(path);
  const metadata = lstatSync(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== process.getuid()) {
    throw new RotationError("Rotation input must be an operator-owned regular non-symlink file.", 66);
  }
  if ((metadata.mode & 0o777) !== 0o600) {
    throw new RotationError("Rotation environment files must use mode 0600.", 66);
  }
  if (metadata.size > maximumBytes) {
    throw new RotationError("Rotation input exceeds the bounded file-size contract.", 66);
  }
  const descriptor = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || opened.dev !== metadata.dev || opened.ino !== metadata.ino) {
      throw new RotationError("Rotation input changed while it was opened.", 73);
    }
    const data = readFileSync(descriptor);
    const completed = lstatSync(path);
    if (completed.dev !== metadata.dev || completed.ino !== metadata.ino || completed.size !== metadata.size) {
      throw new RotationError("Rotation input changed while it was read.", 73);
    }
    return data;
  } finally {
    closeSync(descriptor);
  }
}

function parseEnv(data) {
  const text = data.toString("utf8");
  if (Buffer.from(text, "utf8").length !== data.length || text.includes("\0")) {
    throw new RotationError("Rotation environment must be valid UTF-8 text.");
  }
  const values = new Map();
  for (const [index, raw] of text.split(/\r?\n/).entries()) {
    const trimmed = raw.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(trimmed);
    if (!match) throw new RotationError(`Malformed environment assignment on line ${index + 1}.`);
    const [, name] = match;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else if (value.startsWith('"') || value.endsWith('"') || value.startsWith("'") || value.endsWith("'")) {
      throw new RotationError(`Unbalanced environment quoting on line ${index + 1}.`);
    }
    if (values.has(name)) throw new RotationError(`Duplicate environment key: ${name}.`);
    values.set(name, value);
  }
  return values;
}

function validatePassword(name, value) {
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(value ?? "") || /(replace|change[_-]?me|example|password)/i.test(value)) {
    throw new RotationError(`${name} does not satisfy the URL-safe credential contract.`);
  }
}

function validateDatabaseUrl(name, value, username, password, baseline) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new RotationError(`${name} is not a valid PostgreSQL URL.`);
  }
  if (!["postgres:", "postgresql:"].includes(parsed.protocol)
      || parsed.username !== username || parsed.password !== password
      || !parsed.hostname || parsed.hash || parsed.pathname === "/") {
    throw new RotationError(`${name} does not bind the exact expected role credential.`);
  }
  // Credentials are deliberately URL-safe, so this exact prefix check both
  // rejects alternate encodings and lets us retain the non-credential URL
  // byte-for-byte. TLS parameters, query ordering, explicit port, protocol,
  // host spelling, and database path cannot drift in a credential-only change.
  const credentialPrefix = `${parsed.protocol}//${username}:${password}@`;
  if (!value.startsWith(credentialPrefix)) {
    throw new RotationError(`${name} does not use the canonical expected role credential.`);
  }
  const endpoint = `${parsed.protocol}//${value.slice(credentialPrefix.length)}`;
  if (baseline !== undefined && endpoint !== baseline) {
    throw new RotationError(`${name} changed the database endpoint or TLS contract during credential rotation.`);
  }
  return endpoint;
}

function validateEnvContract(currentPath, nextPath) {
  if (resolve(nextPath) !== `${resolve(currentPath)}.next`) {
    throw new RotationError("The next environment must be the current environment path plus .next.", 66);
  }
  const currentData = readPrivateFile(resolve(currentPath));
  const nextData = readPrivateFile(resolve(nextPath));
  const current = parseEnv(currentData);
  const next = parseEnv(nextData);
  if (current.size !== next.size || [...current.keys()].some((key) => !next.has(key))) {
    throw new RotationError("Current and next environments must contain the same exact key set.");
  }
  for (const [key, value] of current) {
    if (!CREDENTIAL_KEYS.has(key) && next.get(key) !== value) {
      throw new RotationError(`Non-credential environment key changed: ${key}.`);
    }
  }
  for (const key of CREDENTIAL_KEYS) {
    if (!current.has(key) || !next.has(key) || current.get(key) === next.get(key)) {
      throw new RotationError(`Rotation must change exactly the credential field ${key}.`);
    }
  }
  if ((current.get("ADDRESS_ATLAS_DATABASE_ROLE_MODE") ?? "steady") !== "steady"
      || (next.get("ADDRESS_ATLAS_DATABASE_ROLE_MODE") ?? "steady") !== "steady") {
    throw new RotationError("Credential rotation requires steady database-role mode.");
  }
  const oldSecrets = [
    current.get("POSTGRES_PASSWORD"), current.get("POSTGRES_ADMIN_PASSWORD"),
    current.get("POSTGRES_RUNTIME_PASSWORD")
  ];
  const newSecrets = [
    next.get("POSTGRES_PASSWORD"), next.get("POSTGRES_ADMIN_PASSWORD"),
    next.get("POSTGRES_RUNTIME_PASSWORD")
  ];
  ["POSTGRES_PASSWORD", "POSTGRES_ADMIN_PASSWORD", "POSTGRES_RUNTIME_PASSWORD"].forEach((key, index) => {
    validatePassword(`current ${key}`, oldSecrets[index]);
    validatePassword(`next ${key}`, newSecrets[index]);
  });
  if (new Set([...oldSecrets, ...newSecrets]).size !== 6) {
    throw new RotationError("Current and next role credentials must be six distinct values.");
  }
  const currentOwnerEndpoint = validateDatabaseUrl(
    "current SYNC_SCHEMA_DATABASE_URL", current.get("SYNC_SCHEMA_DATABASE_URL"),
    "address_atlas", oldSecrets[0]
  );
  validateDatabaseUrl(
    "next SYNC_SCHEMA_DATABASE_URL", next.get("SYNC_SCHEMA_DATABASE_URL"),
    "address_atlas", newSecrets[0], currentOwnerEndpoint
  );
  const currentRuntimeEndpoint = validateDatabaseUrl(
    "current SYNC_DATABASE_URL", current.get("SYNC_DATABASE_URL"),
    "address_atlas_runtime", oldSecrets[2]
  );
  validateDatabaseUrl(
    "next SYNC_DATABASE_URL", next.get("SYNC_DATABASE_URL"),
    "address_atlas_runtime", newSecrets[2], currentRuntimeEndpoint
  );
  if (currentOwnerEndpoint !== currentRuntimeEndpoint) {
    throw new RotationError("Owner and runtime URLs must name the same PostgreSQL endpoint.");
  }
  return { currentHash: sha256(currentData), nextHash: sha256(nextData) };
}

function assertToken(value, expression, label) {
  if (!expression.test(value ?? "")) throw new RotationError(`Rotation state ${label} is invalid.`, 66);
  return value;
}

function validateState(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...STATE_KEYS].sort())
      || value.schemaVersion !== 3 || !PHASES.includes(value.phase)) {
    throw new RotationError("Credential-rotation state has an invalid schema.", 66);
  }
  assertToken(value.currentEnvHash, /^[0-9a-f]{64}$/, "current environment hash");
  assertToken(value.nextEnvHash, /^[0-9a-f]{64}$/, "next environment hash");
  assertToken(value.sourceRevision, /^[0-9a-f]{40}$/, "source revision");
  for (const key of ["manageProdSha256", "stateToolSha256", "composeSha256",
    "provisionSha256", "backupToolSha256"]) {
    assertToken(value[key], /^[0-9a-f]{64}$/, key);
  }
  assertToken(value.backupSha256, /^[0-9a-f]{64}$/, "backup hash");
  assertToken(value.revision, /^[0-9a-f]{40}$/, "revision");
  assertToken(value.webImageId, /^sha256:[0-9a-f]{64}$/, "web image");
  for (const key of ["webContainerId", "caddyContainerId", "postgresContainerId"]) {
    assertToken(value[key], /^[0-9a-f]{12,64}$/, key);
  }
  assertToken(value.postgresVolume, /^[A-Za-z0-9][A-Za-z0-9_.-]+$/, "PostgreSQL volume");
  if (!isAbsolute(value.backupPath) || value.backupPath.includes("|") || /[\r\n]/.test(value.backupPath)) {
    throw new RotationError("Rotation state backup path is invalid.", 66);
  }
  return value;
}

function readState(path) {
  const data = readPrivateFile(path);
  if (data.length > 32_768) throw new RotationError("Credential-rotation state is oversized.", 66);
  return validateState(JSON.parse(data.toString("utf8")));
}

function writeAtomic(path, data, mustNotExist = false) {
  assertSafeParent(path);
  if (mustNotExist) {
    try {
      lstatSync(path);
      throw new RotationError("Credential-rotation state already exists.", 75);
    } catch (error) {
      if (!(error && error.code === "ENOENT")) throw error;
    }
  }
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  let descriptor = -1;
  try {
    descriptor = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
    writeFileSync(descriptor, data);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = -1;
    renameSync(temporary, path);
    const directory = openSync(dirname(path), constants.O_RDONLY);
    try { fsyncSync(directory); } finally { closeSync(directory); }
  } catch (error) {
    if (descriptor >= 0) closeSync(descriptor);
    try { unlinkSync(temporary); } catch {}
    throw error;
  }
}

function writeState(path, state, mustNotExist = false) {
  validateState(state);
  writeAtomic(path, `${JSON.stringify(state)}\n`, mustNotExist);
}

function unlinkDurably(path) {
  unlinkSync(path);
  const directory = openSync(dirname(path), constants.O_RDONLY);
  try { fsyncSync(directory); } finally { closeSync(directory); }
}

function usage() {
  throw new RotationError(
    "Usage: credential-rotation-state.mjs {env-contract <current> <next>|resume-contract <state> <current> <next> <source-revision> <manage-prod-hash> <state-tool-hash> <compose-hash> <provision-hash> <backup-tool-hash>|state-write <path> <phase> <current-hash> <next-hash> <source-revision> <manage-prod-hash> <state-tool-hash> <compose-hash> <provision-hash> <backup-tool-hash> <backup> <backup-hash> <revision> <web-image> <web-container> <caddy-container> <postgres-container> <postgres-volume>|state-read <path>|state-advance <path> <expected> <next>|install-env <source> <target> <current-hash> <next-hash>|state-delete <path> <next-hash>|cleanup-next <path> <next-hash>|run-with-deadline <seconds> -- <command> [arguments...]}",
    64
  );
}

async function runWithDeadline(secondsRaw, command, commandArguments) {
  if (!/^[1-9][0-9]*$/.test(secondsRaw ?? "")
      || Number(secondsRaw) > 900 || !command || /[\r\n]/.test(command)) {
    throw new RotationError("Bounded rotation command arguments are invalid.", 64);
  }
  const timeoutMilliseconds = Number(secondsRaw) * 1000;
  return await new Promise((resolvePromise) => {
    let child;
    let timedOut = false;
    let settled = false;
    let deadlineTimer;
    let forceTimer;
    const forwardedSignals = ["SIGINT", "SIGTERM", "SIGHUP"];

    const signalChild = (signal) => {
      if (!child?.pid) return;
      try {
        if (process.platform === "win32") child.kill(signal);
        else process.kill(-child.pid, signal);
      } catch {}
    };
    const handlers = new Map(forwardedSignals.map((signal) => [signal, () => signalChild(signal)]));
    const finish = (status) => {
      if (settled) return;
      settled = true;
      if (deadlineTimer) clearTimeout(deadlineTimer);
      if (forceTimer) clearTimeout(forceTimer);
      for (const [signal, handler] of handlers) process.off(signal, handler);
      resolvePromise(status);
    };

    try {
      child = spawn(command, commandArguments, {
        stdio: "inherit",
        detached: process.platform !== "win32",
        shell: false
      });
    } catch {
      resolvePromise(69);
      return;
    }
    for (const [signal, handler] of handlers) process.on(signal, handler);
    child.once("error", () => finish(69));
    child.once("exit", (code, signal) => {
      if (timedOut) finish(124);
      else if (Number.isInteger(code)) finish(code);
      else if (signal) finish({ SIGINT: 130, SIGTERM: 143, SIGHUP: 129, SIGKILL: 137 }[signal] ?? 74);
      else finish(74);
    });
    deadlineTimer = setTimeout(() => {
      timedOut = true;
      signalChild("SIGTERM");
      forceTimer = setTimeout(() => signalChild("SIGKILL"), 5_000);
    }, timeoutMilliseconds);
  });
}

try {
  const [command, ...args] = process.argv.slice(2);
  if (command === "env-contract" && args.length === 2) {
    const result = validateEnvContract(args[0], args[1]);
    process.stdout.write(`${result.currentHash}|${result.nextHash}\n`);
  } else if (command === "resume-contract" && args.length === 9) {
    const state = readState(args[0]);
    const currentPath = resolve(args[1]);
    const nextPath = resolve(args[2]);
    const [sourceRevision, manageProdSha256, stateToolSha256, composeSha256,
      provisionSha256, backupToolSha256] = args.slice(3);
    if (sourceRevision !== state.sourceRevision
        || manageProdSha256 !== state.manageProdSha256
        || stateToolSha256 !== state.stateToolSha256
        || composeSha256 !== state.composeSha256
        || provisionSha256 !== state.provisionSha256
        || backupToolSha256 !== state.backupToolSha256) {
      throw new RotationError("Credential-rotation source revision or recovery toolchain differs from the journal contract.", 73);
    }
    if (nextPath !== `${currentPath}.next`) {
      throw new RotationError("The resumed next environment path differs from the journal contract.", 73);
    }
    const currentHash = sha256(readPrivateFile(currentPath));
    if (![state.currentEnvHash, state.nextEnvHash].includes(currentHash)) {
      throw new RotationError("Production environment differs from both journaled rotation versions.", 73);
    }
    let nextPresent = true;
    let nextHash = "";
    try {
      nextHash = sha256(readPrivateFile(nextPath));
    } catch (error) {
      if (!(error && error.code === "ENOENT") || state.phase !== "service-verified"
          || currentHash !== state.nextEnvHash) throw error;
      nextPresent = false;
    }
    if (nextPresent && nextHash !== state.nextEnvHash) {
      throw new RotationError("Next environment differs from the journaled rotation version.", 73);
    }
    if (state.phase === "prepared" && currentHash !== state.currentEnvHash) {
      throw new RotationError("Prepared rotation unexpectedly replaced the production environment.", 73);
    }
    if (["environment-committed", "service-verified"].includes(state.phase)
        && currentHash !== state.nextEnvHash) {
      throw new RotationError("Committed rotation phase lacks the new production environment.", 73);
    }
    process.stdout.write(`${currentHash}|${nextPresent ? "present" : "consumed"}\n`);
  } else if (command === "state-write" && args.length === 18) {
    const [path, phase, currentEnvHash, nextEnvHash, sourceRevision,
      manageProdSha256, stateToolSha256, composeSha256, provisionSha256,
      backupToolSha256, backupPath, backupSha256, revision, webImageId, webContainerId,
      caddyContainerId, postgresContainerId, postgresVolume] = args;
    writeState(path, { schemaVersion: 3, phase, currentEnvHash, nextEnvHash,
      sourceRevision, manageProdSha256, stateToolSha256, composeSha256,
      provisionSha256, backupToolSha256, backupPath, backupSha256, revision, webImageId,
      webContainerId, caddyContainerId, postgresContainerId, postgresVolume }, true);
  } else if (command === "state-read" && args.length === 1) {
    const state = readState(args[0]);
    process.stdout.write(STATE_KEYS.map((key) => state[key]).join("|") + "\n");
  } else if (command === "state-advance" && args.length === 3) {
    const state = readState(args[0]);
    if (state.phase !== args[1] || PHASES.indexOf(args[2]) !== PHASES.indexOf(args[1]) + 1) {
      throw new RotationError("Credential-rotation phase transition is invalid.", 73);
    }
    writeState(args[0], { ...state, phase: args[2] });
  } else if (command === "install-env" && args.length === 4) {
    const [source, target, currentHash, nextHash] = args;
    assertToken(currentHash, /^[0-9a-f]{64}$/, "current environment hash");
    assertToken(nextHash, /^[0-9a-f]{64}$/, "next environment hash");
    const sourceData = readPrivateFile(source);
    const targetData = readPrivateFile(target);
    if (sha256(sourceData) !== nextHash || ![currentHash, nextHash].includes(sha256(targetData))) {
      throw new RotationError("Environment files do not match the journaled rotation hashes.", 73);
    }
    if (sha256(targetData) === currentHash) writeAtomic(target, sourceData);
  } else if (command === "state-delete" && args.length === 2) {
    const state = readState(args[0]);
    if (state.phase !== "service-verified" || state.nextEnvHash !== args[1]) {
      throw new RotationError("Only a service-verified rotation state can be deleted.", 73);
    }
    unlinkDurably(args[0]);
  } else if (command === "cleanup-next" && args.length === 2) {
    const data = readPrivateFile(args[0]);
    if (sha256(data) !== args[1]) throw new RotationError("Next environment hash changed before cleanup.", 73);
    unlinkDurably(args[0]);
  } else if (command === "run-with-deadline" && args.length >= 3 && args[1] === "--") {
    process.exitCode = await runWithDeadline(args[0], args[2], args.slice(3));
  } else {
    usage();
  }
} catch (error) {
  const status = error instanceof RotationError ? error.status : 74;
  console.error(error instanceof RotationError ? error.message : "Credential-rotation state operation failed closed.");
  process.exitCode = status;
}
